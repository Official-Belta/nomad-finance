#!/usr/bin/env python3
"""
Nomad Finance — Improved Weekly Epoch Backtest (v2)
====================================================
Phase A: Regime detection + dynamic allocation
Phase B: Daily delta recalculation hedge
Phase C: Position sizing + stop-loss + vol filter

Usage: python3 run_weekly_backtest.py
"""

import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np

from pricing import (
    bsm_call, bsm_put, delta_call, delta_put,
    find_strike_by_delta, ewma_vol, gamma, vega
)
from eth_weekly_prices import (
    ETH_WEEKLY_CLOSE, WEEK_DATES,
    get_daily_prices_from_weekly, get_weekly_returns
)
from regime import (
    Regime, classify_regime, get_regime_weights, get_cash_weight,
    classify_all_weeks, print_regime_summary
)


# =============================================================================
#                       IMPROVED BACKTESTER (v2)
# =============================================================================

class ImprovedBacktester:
    """
    개선된 주간 에포크 백테스터.
    - 레짐 기반 동적 배분
    - 일간 delta 재계산 헤지
    - 리스크 버짓 포지션 사이징
    - Stop-loss 조기 퇴출
    - Vol premium 필터
    """

    # Risk parameters
    MAX_LOSS_PER_EPOCH = 0.03   # 3% of NAV max loss per epoch
    STOP_LOSS_THRESHOLD = 0.05  # 5% of NAV → early exit
    VOL_PREMIUM_MIN = 0.05      # 5% annualized min IV-RV spread to sell
    IV_RV_RATIO = 1.15          # crypto IV typically 15% above RV

    def __init__(self, weekly_prices: np.ndarray, week_dates: list[str],
                 capital: float = 1_000_000):
        self.prices = weekly_prices
        self.dates = week_dates
        self.capital = capital
        self.n_weeks = len(weekly_prices) - 1

        self.daily = get_daily_prices_from_weekly(weekly_prices)
        daily_rets = np.diff(np.log(self.daily))
        daily_rets = np.insert(daily_rets, 0, 0)
        self.daily_vol = ewma_vol(daily_rets, lam=0.94)

        self.weekly_rets = get_weekly_returns(weekly_prices)
        self.weekly_vol = self._calc_weekly_vol()
        self.regimes = classify_all_weeks(weekly_prices)

    def _calc_weekly_vol(self) -> np.ndarray:
        rets = self.weekly_rets
        vols = np.zeros(len(rets))
        for i in range(len(rets)):
            lookback = max(0, i - 3)
            window = rets[lookback:i + 1]
            vols[i] = np.std(window) * np.sqrt(52) if len(window) > 1 else 0.70
        return np.clip(vols, 0.30, 2.00)

    # =========================================================================
    #                    VOL PREMIUM FILTER
    # =========================================================================

    def _has_vol_premium(self, week_idx: int) -> bool:
        """Check if IV > RV enough to justify selling options."""
        rv = self.weekly_vol[week_idx] if week_idx < len(self.weekly_vol) else 0.70
        iv_estimate = rv * self.IV_RV_RATIO
        return (iv_estimate - rv) >= self.VOL_PREMIUM_MIN

    # =========================================================================
    #                    POSITION SIZING
    # =========================================================================

    def _calc_notional(self, S: float, sigma: float, T: float, nav: float,
                       max_loss_mult: float = 2.0) -> float:
        """
        Risk-budget position sizing.
        max_loss = max_loss_mult * sigma * sqrt(T) * S * (notional / S)
        Solve for notional such that max_loss <= nav * MAX_LOSS_PER_EPOCH.
        """
        expected_move = max_loss_mult * sigma * np.sqrt(T) * S
        if expected_move <= 0:
            return 0
        max_notional_ratio = (nav * self.MAX_LOSS_PER_EPOCH) / expected_move
        # Cap at 100% of NAV
        notional_ratio = min(max_notional_ratio, nav / S)
        return max(notional_ratio, 0)

    # =========================================================================
    #                 IMPROVED DELTA HEDGE (daily recalc)
    # =========================================================================

    def _hedge_with_daily_recalc(self, week_idx: int, strike: float,
                                  is_call: bool, sigma: float,
                                  notional: float, is_short: bool = True) -> float:
        """
        Delta hedge with daily recalculation.
        Recomputes delta at each daily step using current spot and remaining T.
        """
        start_day = week_idx * 7
        end_day = min(start_day + 7, len(self.daily) - 1)
        if start_day >= len(self.daily) - 1:
            return 0

        daily_slice = self.daily[start_day:end_day + 1]
        if len(daily_slice) < 2:
            return 0

        total_pnl = 0.0
        prev_price = daily_slice[0]
        prev_hedge_pos = 0.0

        for d in range(len(daily_slice)):
            S = daily_slice[d]
            T_remaining = max((7 - d) / 365.25, 1e-6)

            # Recalculate delta at current spot
            if is_call:
                d_val = delta_call(S, strike, T_remaining, sigma)
            else:
                d_val = delta_put(S, strike, T_remaining, sigma)

            # For short option, hedge sign is flipped
            target_hedge = -d_val * notional / S if is_short else d_val * notional / S

            if d > 0:
                # PnL from existing hedge
                price_change = S - prev_price
                total_pnl += prev_hedge_pos * price_change

                # Slippage on rebalance
                rebalance_size = abs(target_hedge - prev_hedge_pos) * S
                total_pnl -= rebalance_size * 0.0003  # 3bps per rebalance

            prev_hedge_pos = target_hedge
            prev_price = S

        return total_pnl

    def _hedge_straddle(self, week_idx: int, strike: float, sigma: float,
                        notional: float) -> float:
        """Delta hedge for short straddle (short call + short put)."""
        start_day = week_idx * 7
        end_day = min(start_day + 7, len(self.daily) - 1)
        if start_day >= len(self.daily) - 1:
            return 0

        daily_slice = self.daily[start_day:end_day + 1]
        if len(daily_slice) < 2:
            return 0

        total_pnl = 0.0
        prev_price = daily_slice[0]
        prev_hedge_pos = 0.0

        for d in range(len(daily_slice)):
            S = daily_slice[d]
            T_remaining = max((7 - d) / 365.25, 1e-6)

            cd = delta_call(S, strike, T_remaining, sigma)
            pd = delta_put(S, strike, T_remaining, sigma)
            net_delta = -(cd + pd)  # short both
            target_hedge = net_delta * notional / S

            if d > 0:
                price_change = S - prev_price
                total_pnl += prev_hedge_pos * price_change
                rebalance_size = abs(target_hedge - prev_hedge_pos) * S
                total_pnl -= rebalance_size * 0.0003

            prev_hedge_pos = target_hedge
            prev_price = S

        return total_pnl

    # =========================================================================
    #                    STOP-LOSS CHECK
    # =========================================================================

    def _check_stop_loss(self, week_idx: int, strike: float, is_call: bool,
                         premium: float, notional: float, nav: float,
                         sigma: float) -> tuple[bool, float, float]:
        """
        Check intra-week if unrealized loss exceeds threshold.
        Returns (triggered, exit_day_price, realized_pnl).
        """
        start_day = week_idx * 7
        end_day = min(start_day + 7, len(self.daily) - 1)

        for d in range(1, end_day - start_day + 1):
            day_idx = start_day + d
            if day_idx >= len(self.daily):
                break

            S = self.daily[day_idx]
            T_remaining = max((7 - d) / 365.25, 1e-6)

            if is_call:
                mtm = bsm_call(S, strike, T_remaining, sigma)
            else:
                mtm = bsm_put(S, strike, T_remaining, sigma)

            unrealized_loss = (mtm - premium) * notional
            if unrealized_loss > nav * self.STOP_LOSS_THRESHOLD:
                realized_pnl = (premium - mtm) * notional
                return True, S, realized_pnl

        return False, 0, 0

    # =========================================================================
    #                    INDIVIDUAL STRATEGIES (single epoch)
    # =========================================================================

    def _cc_one_epoch(self, w: int, nav: float, target_delta: float = 0.25) -> dict:
        """Covered Call: single epoch."""
        S, S_end = self.prices[w], self.prices[w + 1]
        sigma = self.weekly_vol[w]
        T = 7 / 365.25

        strike = find_strike_by_delta(S, sigma, T, target_delta, is_call=True)
        premium = bsm_call(S, strike, T, sigma)
        notional = self._calc_notional(S, sigma, T, nav)

        # Stop-loss check
        stopped, exit_price, stop_pnl = self._check_stop_loss(
            w, strike, True, premium, notional, nav, sigma)

        if stopped:
            hedge_pnl = self._hedge_with_daily_recalc(w, strike, True, sigma, notional)
            return {'total_pnl': stop_pnl + hedge_pnl, 'premium': premium * notional,
                    'option_pnl': stop_pnl, 'hedge_pnl': hedge_pnl, 'stopped': True}

        call_payoff = max(S_end - strike, 0)
        option_pnl = (premium - call_payoff) * notional
        hedge_pnl = self._hedge_with_daily_recalc(w, strike, True, sigma, notional)

        return {'total_pnl': option_pnl + hedge_pnl, 'premium': premium * notional,
                'option_pnl': option_pnl, 'hedge_pnl': hedge_pnl, 'stopped': False}

    def _csp_one_epoch(self, w: int, nav: float, target_delta: float = 0.25) -> dict:
        """Cash-Secured Put: single epoch."""
        S, S_end = self.prices[w], self.prices[w + 1]
        sigma = self.weekly_vol[w]
        T = 7 / 365.25

        strike = find_strike_by_delta(S, sigma, T, target_delta, is_call=False)
        premium = bsm_put(S, strike, T, sigma)
        notional = self._calc_notional(S, sigma, T, nav)

        stopped, _, stop_pnl = self._check_stop_loss(
            w, strike, False, premium, notional, nav, sigma)

        if stopped:
            hedge_pnl = self._hedge_with_daily_recalc(w, strike, False, sigma, notional)
            return {'total_pnl': stop_pnl + hedge_pnl, 'premium': premium * notional,
                    'option_pnl': stop_pnl, 'hedge_pnl': hedge_pnl, 'stopped': True}

        put_payoff = max(strike - S_end, 0)
        option_pnl = (premium - put_payoff) * notional
        hedge_pnl = self._hedge_with_daily_recalc(w, strike, False, sigma, notional)

        return {'total_pnl': option_pnl + hedge_pnl, 'premium': premium * notional,
                'option_pnl': option_pnl, 'hedge_pnl': hedge_pnl, 'stopped': False}

    def _ic_one_epoch(self, w: int, nav: float, short_delta: float = 0.20,
                      spread_pct: float = 0.05) -> dict:
        """Iron Condor: single epoch."""
        S, S_end = self.prices[w], self.prices[w + 1]
        sigma = self.weekly_vol[w]
        T = 7 / 365.25

        sc_K = find_strike_by_delta(S, sigma, T, short_delta, is_call=True)
        sp_K = find_strike_by_delta(S, sigma, T, short_delta, is_call=False)
        spread = S * spread_pct
        lc_K = sc_K + spread
        lp_K = max(sp_K - spread, 1)

        net_prem = (bsm_call(S, sc_K, T, sigma) + bsm_put(S, sp_K, T, sigma)
                    - bsm_call(S, lc_K, T, sigma) - bsm_put(S, lp_K, T, sigma))

        # IC max loss is capped by spread width
        max_loss_per_unit = spread - net_prem
        if max_loss_per_unit <= 0:
            max_loss_per_unit = spread
        notional = min(
            (nav * self.MAX_LOSS_PER_EPOCH) / max_loss_per_unit * S,
            nav / S * 0.5
        )

        sc_payoff = max(S_end - sc_K, 0) - max(S_end - lc_K, 0)
        sp_payoff = max(sp_K - S_end, 0) - max(lp_K - S_end, 0)
        option_pnl = (net_prem - sc_payoff - sp_payoff) * notional

        # Hedge net delta
        cd = delta_call(S, sc_K, T, sigma)
        pd = delta_put(S, sp_K, T, sigma)
        hedge_pnl = self._hedge_straddle(w, (sc_K + sp_K) / 2, sigma, notional * 0.3)

        return {'total_pnl': option_pnl + hedge_pnl, 'premium': net_prem * notional,
                'option_pnl': option_pnl, 'hedge_pnl': hedge_pnl, 'stopped': False}

    def _bcs_one_epoch(self, w: int, nav: float, long_delta: float = 0.55,
                       short_delta: float = 0.25) -> dict:
        """Bull Call Spread: single epoch."""
        S, S_end = self.prices[w], self.prices[w + 1]
        sigma = self.weekly_vol[w]
        T = 7 / 365.25

        long_K = find_strike_by_delta(S, sigma, T, long_delta, is_call=True)
        short_K = find_strike_by_delta(S, sigma, T, short_delta, is_call=True)
        if short_K <= long_K:
            short_K = long_K * 1.03

        long_prem = bsm_call(S, long_K, T, sigma)
        short_prem = bsm_call(S, short_K, T, sigma)
        net_debit = long_prem - short_prem

        # Risk is limited to net debit
        risk_per_unit = net_debit if net_debit > 0 else 1
        notional = min(nav * 0.05 / risk_per_unit, nav / S)

        long_payoff = max(S_end - long_K, 0)
        short_payoff = max(S_end - short_K, 0)
        option_pnl = ((long_payoff - short_payoff) - net_debit) * notional

        return {'total_pnl': option_pnl, 'premium': -net_debit * notional,
                'option_pnl': option_pnl, 'hedge_pnl': 0, 'stopped': False}

    def _straddle_one_epoch(self, w: int, nav: float) -> dict:
        """Short Straddle: single epoch."""
        S, S_end = self.prices[w], self.prices[w + 1]
        sigma = self.weekly_vol[w]
        T = 7 / 365.25
        strike = S

        call_prem = bsm_call(S, strike, T, sigma)
        put_prem = bsm_put(S, strike, T, sigma)
        total_prem = call_prem + put_prem

        notional = self._calc_notional(S, sigma, T, nav, max_loss_mult=2.5)

        call_payoff = max(S_end - strike, 0)
        put_payoff = max(strike - S_end, 0)
        option_pnl = (total_prem - call_payoff - put_payoff) * notional

        hedge_pnl = self._hedge_straddle(w, strike, sigma, notional)

        return {'total_pnl': option_pnl + hedge_pnl, 'premium': total_prem * notional,
                'option_pnl': option_pnl, 'hedge_pnl': hedge_pnl, 'stopped': False}

    # =========================================================================
    #                   FULL STRATEGY RUNS (for comparison)
    # =========================================================================

    def run_strategy(self, name: str, epoch_fn, **kwargs) -> dict:
        """Run a single strategy across all epochs."""
        nav = self.capital
        results = []
        for w in range(self.n_weeks):
            # Vol premium filter for selling strategies
            if name in ("CoveredCall", "CashSecuredPut", "IronCondor", "Straddle"):
                if not self._has_vol_premium(w):
                    results.append(self._idle_epoch(w, nav))
                    continue

            res = epoch_fn(w, nav, **kwargs)
            results.append({
                'week': w, 'date': self.dates[w],
                'entry': self.prices[w], 'exit': self.prices[w + 1],
                'total_pnl': res['total_pnl'],
                'premium': res['premium'],
                'option_pnl': res['option_pnl'],
                'hedge_pnl': res['hedge_pnl'],
                'nav_before': nav,
                'vol': self.weekly_vol[w] if w < len(self.weekly_vol) else 0,
                'stopped': res.get('stopped', False),
                'regime': self.regimes[w].value if w < len(self.regimes) else '',
            })
            nav += res['total_pnl']

        return self._build_report(name, results, nav)

    def _idle_epoch(self, w: int, nav: float) -> dict:
        return {
            'week': w, 'date': self.dates[w],
            'entry': self.prices[w], 'exit': self.prices[w + 1],
            'total_pnl': 0, 'premium': 0, 'option_pnl': 0,
            'hedge_pnl': 0, 'nav_before': nav, 'vol': 0,
            'stopped': False, 'regime': self.regimes[w].value if w < len(self.regimes) else '',
        }

    # =========================================================================
    #              DYNAMIC AUTO VAULT (regime-aware per-epoch allocation)
    # =========================================================================

    def auto_vault_dynamic(self, tier_override: str = None) -> dict:
        """
        Dynamic AutoVault: per-epoch regime detection → weight allocation.
        Unlike v1 which ran sub-strategies independently with fixed weights,
        v2 allocates capital epoch-by-epoch based on regime.
        """
        nav = self.capital
        results = []
        strategy_fns = {
            "CC": self._cc_one_epoch,
            "CSP": self._csp_one_epoch,
            "IC": self._ic_one_epoch,
            "BCS": self._bcs_one_epoch,
            "STR": self._straddle_one_epoch,
        }

        for w in range(self.n_weeks):
            regime = self.regimes[w] if w < len(self.regimes) else Regime.LOW_VOL_SIDEWAYS

            if tier_override:
                # Allow fixed-tier comparison
                STATIC = {
                    "conservative": {"CC": 0.70, "CSP": 0.20, "IC": 0.10, "BCS": 0.00, "STR": 0.00},
                    "moderate":     {"CC": 0.40, "CSP": 0.20, "IC": 0.25, "BCS": 0.10, "STR": 0.05},
                    "aggressive":   {"CC": 0.30, "CSP": 0.10, "IC": 0.30, "BCS": 0.20, "STR": 0.10},
                }
                weights = STATIC[tier_override]
            else:
                weights = get_regime_weights(regime)

            epoch_pnl = 0
            for strat_name, weight in weights.items():
                if weight <= 0:
                    continue

                allocated_nav = nav * weight

                # Vol filter for selling strategies
                if strat_name in ("CC", "CSP", "IC", "STR"):
                    if not self._has_vol_premium(w):
                        continue

                fn = strategy_fns[strat_name]
                res = fn(w, allocated_nav)
                epoch_pnl += res['total_pnl']

            results.append({
                'week': w, 'date': self.dates[w],
                'entry': self.prices[w], 'exit': self.prices[w + 1],
                'total_pnl': epoch_pnl,
                'premium': 0, 'option_pnl': epoch_pnl, 'hedge_pnl': 0,
                'nav_before': nav,
                'vol': self.weekly_vol[w] if w < len(self.weekly_vol) else 0,
                'stopped': False,
                'regime': regime.value,
            })
            nav += epoch_pnl

        label = f"AutoVault (dynamic)" if not tier_override else f"AutoVault ({tier_override}, static)"
        return self._build_report(label, results, nav)

    # =========================================================================
    #                    REPORT BUILDING
    # =========================================================================

    def _build_report(self, name: str, results: list, final_nav: float) -> dict:
        pnls = [r['total_pnl'] for r in results]
        rets = []
        nav = self.capital
        for pnl in pnls:
            rets.append(pnl / nav if nav > 0 else 0)
            nav += pnl

        rets = np.array(rets)
        cum = np.cumprod(1 + rets)
        peak = np.maximum.accumulate(cum)
        dd = (peak - cum) / peak
        max_dd = float(np.max(dd)) if len(dd) > 0 else 0

        total_ret = (final_nav - self.capital) / self.capital
        n = len(results)
        ann_ret = (1 + total_ret) ** (52 / n) - 1 if n > 0 and total_ret > -1 else total_ret
        sharpe = float((np.mean(rets) / np.std(rets)) * np.sqrt(52)) if np.std(rets) > 0 else 0
        win_rate = float(np.mean(np.array(pnls) > 0))

        return {
            'name': name, 'initial_capital': self.capital,
            'final_nav': final_nav, 'total_return': total_ret,
            'annualized_return': ann_ret, 'sharpe': sharpe,
            'max_drawdown': max_dd, 'win_rate': win_rate,
            'n_epochs': n, 'avg_pnl': float(np.mean(pnls)),
            'best_epoch': float(max(pnls)), 'worst_epoch': float(min(pnls)),
            'pnl_std': float(np.std(pnls)), 'epochs': results,
            'weekly_returns': rets, 'cumulative': cum,
        }


# =============================================================================
#                          PRINTING
# =============================================================================

def fmt_pct(x): return f"{x*100:+.2f}%"
def fmt_usd(x): return f"${x:,.0f}"


def print_report(r: dict):
    print(f"\n{'='*70}")
    print(f"  {r['name']}")
    print(f"{'='*70}")
    print(f"  초기 자본:        {fmt_usd(r['initial_capital'])}")
    print(f"  최종 NAV:         {fmt_usd(r['final_nav'])}")
    print(f"  총 수익률:        {fmt_pct(r['total_return'])}")
    print(f"  연환산 APR:       {fmt_pct(r['annualized_return'])}")
    print(f"  Sharpe Ratio:     {r['sharpe']:.2f}")
    print(f"  Max Drawdown:     {fmt_pct(r['max_drawdown'])}")
    print(f"  Win Rate:         {fmt_pct(r['win_rate'])}")
    print(f"  에포크:           {r['n_epochs']}주")
    print(f"  평균 주간 PnL:    {fmt_usd(r['avg_pnl'])}")
    print(f"  최고 / 최저:      {fmt_usd(r['best_epoch'])} / {fmt_usd(r['worst_epoch'])}")
    print(f"  PnL 표준편차:     {fmt_usd(r['pnl_std'])}")


def print_comparison(results: list[dict]):
    print(f"\n{'='*115}")
    print(f"  전략 비교 — 52주 주간 에포크")
    print(f"{'='*115}")
    h = f"  {'전략':<30} {'총수익률':>10} {'연환산APR':>10} {'Sharpe':>8} {'MaxDD':>10} {'WinRate':>10} {'최종NAV':>14}"
    print(h)
    print(f"  {'-'*108}")
    for r in results:
        print(f"  {r['name']:<30} {fmt_pct(r['total_return']):>10} "
              f"{fmt_pct(r['annualized_return']):>10} {r['sharpe']:>8.2f} "
              f"{fmt_pct(r['max_drawdown']):>10} {fmt_pct(r['win_rate']):>10} "
              f"{fmt_usd(r['final_nav']):>14}")


def print_risk_analysis(results: list[dict]):
    print(f"\n  {'전략':<30} {'연속손실':>8} {'Sortino':>8} {'Calmar':>8} {'VaR95%':>10}")
    print(f"  {'-'*70}")
    for r in results:
        rets = r['weekly_returns']
        mc = cc = 0
        for ret in rets:
            if ret < 0: cc += 1; mc = max(mc, cc)
            else: cc = 0
        neg = rets[rets < 0]
        ds = float(np.std(neg)) if len(neg) > 0 else 1e-10
        sortino = float(np.mean(rets) / ds * np.sqrt(52)) if ds > 0 else 0
        calmar = r['annualized_return'] / r['max_drawdown'] if r['max_drawdown'] > 0 else 0
        var95 = float(np.percentile(rets, 5)) if len(rets) > 0 else 0
        print(f"  {r['name']:<30} {mc:>7}주 {sortino:>8.2f} {calmar:>8.2f} {fmt_pct(var95):>10}")


# =============================================================================
#                            MAIN
# =============================================================================

def main():
    print("\n" + "="*70)
    print("  NOMAD FINANCE — 개선된 주간 에포크 백테스트 v2")
    print("  기간: 2025-04-06 ~ 2026-03-30 (52주, 실제 데이터)")
    print("  개선: 레짐감지 + 동적배분 + 일간헤지 + 포지션사이징 + StopLoss")
    print("="*70)

    prices = ETH_WEEKLY_CLOSE
    print(f"\n  ETH: ${prices[0]:,.0f} → ATH ${prices.max():,.0f} → ${prices[-1]:,.0f}")
    print(f"  52주 범위: ${prices.min():,.0f} — ${prices.max():,.0f}")
    wr = get_weekly_returns(prices)
    print(f"  실현 Vol: {np.std(wr) * np.sqrt(52):.1%}")

    bt = ImprovedBacktester(prices, WEEK_DATES, capital=1_000_000)

    # --- Part 1: Regime overview ---
    print("\n" + "#"*70)
    print("  PART 1: 레짐 분류")
    print("#"*70)
    print_regime_summary(prices, WEEK_DATES)

    # --- Part 2: Individual strategies (with improvements) ---
    print("\n\n" + "#"*70)
    print("  PART 2: 개별 전략 (개선 v2)")
    print("#"*70)

    cc = bt.run_strategy("CoveredCall (v2)", bt._cc_one_epoch)
    csp = bt.run_strategy("CashSecuredPut (v2)", bt._csp_one_epoch)
    ic = bt.run_strategy("IronCondor (v2)", bt._ic_one_epoch)
    bcs = bt.run_strategy("BullCallSpread (v2)", bt._bcs_one_epoch)
    strad = bt.run_strategy("Straddle (v2)", bt._straddle_one_epoch)

    individual = [cc, csp, ic, bcs, strad]
    for r in individual:
        print_report(r)
    print_comparison(individual)

    # --- Part 3: AutoVault comparison (static vs dynamic) ---
    print("\n\n" + "#"*70)
    print("  PART 3: AutoVault — Static vs Dynamic 비교")
    print("#"*70)

    static_c = bt.auto_vault_dynamic(tier_override="conservative")
    static_m = bt.auto_vault_dynamic(tier_override="moderate")
    static_a = bt.auto_vault_dynamic(tier_override="aggressive")
    dynamic = bt.auto_vault_dynamic()  # regime-aware

    vault_results = [static_c, static_m, static_a, dynamic]
    for r in vault_results:
        print_report(r)
    print_comparison(vault_results)

    # --- Part 4: Risk analysis ---
    print("\n\n" + "#"*70)
    print("  PART 4: 리스크 분석")
    print("#"*70)
    print_risk_analysis(individual + [dynamic])

    # --- Part 5: v1 vs v2 comparison ---
    print("\n\n" + "#"*70)
    print("  PART 5: v1 (baseline) vs v2 (improved) 비교")
    print("#"*70)

    # Run baseline (old style, no improvements)
    class BaselineBacktester(ImprovedBacktester):
        MAX_LOSS_PER_EPOCH = 1.0     # no limit
        STOP_LOSS_THRESHOLD = 1.0    # never trigger
        VOL_PREMIUM_MIN = -999       # always trade
        IV_RV_RATIO = 1.0

        def _calc_notional(self, S, sigma, T, nav, max_loss_mult=2.0):
            return nav / S  # full capital like v1

        def _hedge_with_daily_recalc(self, week_idx, strike, is_call, sigma, notional, is_short=True):
            # Old-style hedge with fixed init delta
            start_day = week_idx * 7
            end_day = min(start_day + 7, len(self.daily) - 1)
            if start_day >= len(self.daily) - 1: return 0
            daily_slice = self.daily[start_day:end_day + 1]
            if len(daily_slice) < 2: return 0
            S0 = daily_slice[0]
            T0 = 7 / 365.25
            if is_call:
                d0 = delta_call(S0, strike, T0, sigma)
            else:
                d0 = delta_put(S0, strike, T0, sigma)
            sign = -1 if is_short else 1
            hedge_pos = sign * d0 * notional / S0
            total_pnl = 0.0
            prev = S0
            step = max(1, len(daily_slice) // 4)
            for i in range(step, len(daily_slice), step):
                total_pnl += hedge_pos * (daily_slice[i] - prev)
                prev = daily_slice[i]
            total_pnl += hedge_pos * (daily_slice[-1] - prev)
            total_pnl -= notional * 0.0005 * 3
            return total_pnl

        def _hedge_straddle(self, week_idx, strike, sigma, notional):
            h1 = self._hedge_with_daily_recalc(week_idx, strike, True, sigma, notional)
            h2 = self._hedge_with_daily_recalc(week_idx, strike, False, sigma, notional)
            return h1 + h2

    baseline = BaselineBacktester(prices, WEEK_DATES, capital=1_000_000)
    b_cc = baseline.run_strategy("CC (v1 baseline)", baseline._cc_one_epoch)
    b_csp = baseline.run_strategy("CSP (v1 baseline)", baseline._csp_one_epoch)
    b_bcs = baseline.run_strategy("BCS (v1 baseline)", baseline._bcs_one_epoch)
    b_auto = baseline.auto_vault_dynamic(tier_override="moderate")
    b_auto['name'] = "AutoVault (v1 moderate)"

    comparison = [b_cc, cc, b_csp, csp, b_bcs, bcs, b_auto, dynamic]
    print_comparison(comparison)

    # --- Summary ---
    print("\n\n" + "="*70)
    print("  백테스트 완료")
    print("="*70)
    print(f"  v2 AutoVault (dynamic): {fmt_pct(dynamic['annualized_return'])} APR, "
          f"Sharpe {dynamic['sharpe']:.2f}, MaxDD {fmt_pct(dynamic['max_drawdown'])}")

    best = max(individual + [dynamic], key=lambda r: r['annualized_return'])
    print(f"  최고 전략: {best['name']} — {fmt_pct(best['annualized_return'])} APR")
    print()


if __name__ == "__main__":
    main()
