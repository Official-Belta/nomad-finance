#!/usr/bin/env python3
"""
Nomad Finance — Weekly Epoch Backtest (52 weeks)
=================================================
ETH 주간 에포크 기반 백테스트.
기간: 2024-04-01 ~ 2025-03-31 (52주, 실제 과거 데이터)
에포크: 매주 월요일 roll (7일)

Usage: python3 run_weekly_backtest.py
"""

import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
import pandas as pd

from pricing import (
    bsm_call, bsm_put, delta_call, delta_put,
    find_strike_by_delta, ewma_vol, gamma, vega
)
from eth_weekly_prices import (
    ETH_WEEKLY_CLOSE, WEEK_DATES,
    get_daily_prices_from_weekly, get_weekly_returns
)


# =============================================================================
#                  WEEKLY EPOCH STRATEGY SIMULATORS
# =============================================================================

class WeeklyBacktester:
    """주간 에포크 기반 전략 백테스터."""

    def __init__(self, weekly_prices: np.ndarray, week_dates: list[str],
                 capital: float = 1_000_000):
        self.prices = weekly_prices
        self.dates = week_dates
        self.capital = capital
        self.n_weeks = len(weekly_prices) - 1  # 51 tradeable epochs

        # Daily prices for intra-week hedging
        self.daily = get_daily_prices_from_weekly(weekly_prices)

        # EWMA vol from daily returns
        daily_rets = np.diff(np.log(self.daily))
        daily_rets = np.insert(daily_rets, 0, 0)
        self.daily_vol = ewma_vol(daily_rets, lam=0.94)

        # Weekly returns for reference
        self.weekly_rets = get_weekly_returns(weekly_prices)

        # Annualized vol per week (use trailing 4-week realized)
        self.weekly_vol = self._calc_weekly_vol()

    def _calc_weekly_vol(self) -> np.ndarray:
        """Trailing 4-week realized vol, annualized."""
        rets = self.weekly_rets
        vols = np.zeros(len(rets))
        for i in range(len(rets)):
            lookback = max(0, i - 3)
            window = rets[lookback:i + 1]
            if len(window) > 1:
                vols[i] = np.std(window) * np.sqrt(52)
            else:
                vols[i] = 0.70  # default 70%
        # Floor at 30%, cap at 200%
        return np.clip(vols, 0.30, 2.00)

    def covered_call(self, target_delta: float = 0.25) -> dict:
        """Covered Call: 매주 OTM call 매도 + delta hedge."""
        nav = self.capital
        results = []

        for w in range(self.n_weeks):
            S = self.prices[w]
            S_end = self.prices[w + 1]
            sigma = self.weekly_vol[w]
            T = 7 / 365.25

            strike = find_strike_by_delta(S, sigma, T, target_delta, is_call=True)
            premium = bsm_call(S, strike, T, sigma)
            d = delta_call(S, strike, T, sigma)

            # Option settlement
            call_payoff = max(S_end - strike, 0)
            option_pnl = premium - call_payoff

            # Delta hedge: short call → long delta hedge
            hedge_pnl = self._simulate_hedge(w, -d, nav)

            notional = nav / S
            total_pnl = option_pnl * notional + hedge_pnl

            results.append({
                'week': w,
                'date': self.dates[w],
                'entry': S,
                'exit': S_end,
                'strike': strike,
                'premium': premium * notional,
                'option_pnl': option_pnl * notional,
                'hedge_pnl': hedge_pnl,
                'total_pnl': total_pnl,
                'nav_before': nav,
                'vol': sigma,
                'delta': d,
            })
            nav += total_pnl

        return self._build_report("CoveredCall", results, nav)

    def cash_secured_put(self, target_delta: float = 0.25) -> dict:
        """Cash-Secured Put: 매주 OTM put 매도 + delta hedge."""
        nav = self.capital
        results = []

        for w in range(self.n_weeks):
            S = self.prices[w]
            S_end = self.prices[w + 1]
            sigma = self.weekly_vol[w]
            T = 7 / 365.25

            strike = find_strike_by_delta(S, sigma, T, target_delta, is_call=False)
            premium = bsm_put(S, strike, T, sigma)
            d = delta_put(S, strike, T, sigma)

            put_payoff = max(strike - S_end, 0)
            option_pnl = premium - put_payoff

            # Short put → positive delta → short perp hedge
            hedge_pnl = self._simulate_hedge(w, -d, nav)

            notional = nav / S
            total_pnl = option_pnl * notional + hedge_pnl

            results.append({
                'week': w, 'date': self.dates[w],
                'entry': S, 'exit': S_end, 'strike': strike,
                'premium': premium * notional,
                'option_pnl': option_pnl * notional,
                'hedge_pnl': hedge_pnl,
                'total_pnl': total_pnl,
                'nav_before': nav, 'vol': sigma, 'delta': d,
            })
            nav += total_pnl

        return self._build_report("CashSecuredPut", results, nav)

    def iron_condor(self, short_delta: float = 0.20, spread_pct: float = 0.05) -> dict:
        """Iron Condor: 매주 OTM call+put 매도, wings 매수."""
        nav = self.capital
        results = []

        for w in range(self.n_weeks):
            S = self.prices[w]
            S_end = self.prices[w + 1]
            sigma = self.weekly_vol[w]
            T = 7 / 365.25

            sc_K = find_strike_by_delta(S, sigma, T, short_delta, is_call=True)
            sp_K = find_strike_by_delta(S, sigma, T, short_delta, is_call=False)
            spread = S * spread_pct
            lc_K = sc_K + spread
            lp_K = max(sp_K - spread, 1)

            # Net premium (credit)
            net_prem = (bsm_call(S, sc_K, T, sigma) + bsm_put(S, sp_K, T, sigma)
                        - bsm_call(S, lc_K, T, sigma) - bsm_put(S, lp_K, T, sigma))

            # Settlement
            sc_payoff = max(S_end - sc_K, 0) - max(S_end - lc_K, 0)
            sp_payoff = max(sp_K - S_end, 0) - max(lp_K - S_end, 0)
            option_pnl = net_prem - sc_payoff - sp_payoff

            # Near delta-neutral, small hedge
            cd = delta_call(S, sc_K, T, sigma)
            pd = delta_put(S, sp_K, T, sigma)
            net_d = -(cd + pd)
            hedge_pnl = self._simulate_hedge(w, net_d, nav * 0.3, n_rehedge=2)

            notional = nav / S * 0.5
            total_pnl = option_pnl * notional + hedge_pnl

            results.append({
                'week': w, 'date': self.dates[w],
                'entry': S, 'exit': S_end,
                'strike': sc_K,  # show short call strike
                'premium': net_prem * notional,
                'option_pnl': option_pnl * notional,
                'hedge_pnl': hedge_pnl,
                'total_pnl': total_pnl,
                'nav_before': nav, 'vol': sigma, 'delta': net_d,
            })
            nav += total_pnl

        return self._build_report("IronCondor", results, nav)

    def bull_call_spread(self, long_delta: float = 0.55, short_delta: float = 0.25) -> dict:
        """Bull Call Spread: 매주 ATM call 매수 + OTM call 매도."""
        nav = self.capital
        results = []

        for w in range(self.n_weeks):
            S = self.prices[w]
            S_end = self.prices[w + 1]
            sigma = self.weekly_vol[w]
            T = 7 / 365.25

            long_K = find_strike_by_delta(S, sigma, T, long_delta, is_call=True)
            short_K = find_strike_by_delta(S, sigma, T, short_delta, is_call=True)
            if short_K <= long_K:
                short_K = long_K * 1.03

            long_prem = bsm_call(S, long_K, T, sigma)
            short_prem = bsm_call(S, short_K, T, sigma)
            net_debit = long_prem - short_prem

            long_payoff = max(S_end - long_K, 0)
            short_payoff = max(S_end - short_K, 0)
            option_pnl = (long_payoff - short_payoff) - net_debit

            # Size: risk max 5% of capital per trade
            risk_per_trade = net_debit if net_debit > 0 else 1
            notional = min(nav * 0.05 / risk_per_trade, nav / S)
            total_pnl = option_pnl * notional

            results.append({
                'week': w, 'date': self.dates[w],
                'entry': S, 'exit': S_end,
                'strike': long_K,
                'premium': -net_debit * notional,
                'option_pnl': option_pnl * notional,
                'hedge_pnl': 0,
                'total_pnl': total_pnl,
                'nav_before': nav, 'vol': sigma, 'delta': 0,
            })
            nav += total_pnl

        return self._build_report("BullCallSpread", results, nav)

    def straddle(self) -> dict:
        """Short Straddle: 매주 ATM call+put 매도, 적극 헤지."""
        nav = self.capital
        results = []

        for w in range(self.n_weeks):
            S = self.prices[w]
            S_end = self.prices[w + 1]
            sigma = self.weekly_vol[w]
            T = 7 / 365.25

            strike = S
            call_prem = bsm_call(S, strike, T, sigma)
            put_prem = bsm_put(S, strike, T, sigma)
            total_prem = call_prem + put_prem

            call_payoff = max(S_end - strike, 0)
            put_payoff = max(strike - S_end, 0)
            option_pnl = total_prem - call_payoff - put_payoff

            cd = delta_call(S, strike, T, sigma)
            pd = delta_put(S, strike, T, sigma)
            net_d = -(cd + pd)

            # Straddle: high gamma → more frequent rehedging
            hedge_pnl = self._simulate_hedge(w, net_d, nav * 0.5, n_rehedge=5)

            notional = nav / S * 0.5
            total_pnl = option_pnl * notional + hedge_pnl

            results.append({
                'week': w, 'date': self.dates[w],
                'entry': S, 'exit': S_end,
                'strike': strike,
                'premium': total_prem * notional,
                'option_pnl': option_pnl * notional,
                'hedge_pnl': hedge_pnl,
                'total_pnl': total_pnl,
                'nav_before': nav, 'vol': sigma, 'delta': net_d,
            })
            nav += total_pnl

        return self._build_report("Straddle", results, nav)

    def auto_vault(self, tier: str = "moderate") -> dict:
        """AutoVault: 멀티 전략 가중 배분."""
        TIERS = {
            "conservative": {"CC": 0.70, "CSP": 0.20, "IC": 0.10, "BCS": 0.00, "STR": 0.00},
            "moderate":     {"CC": 0.40, "CSP": 0.20, "IC": 0.25, "BCS": 0.10, "STR": 0.05},
            "aggressive":   {"CC": 0.30, "CSP": 0.10, "IC": 0.30, "BCS": 0.20, "STR": 0.10},
        }
        weights = TIERS[tier]

        # Run each sub-strategy with allocated capital
        sub = {}
        if weights["CC"] > 0:
            bt = WeeklyBacktester(self.prices, self.dates, self.capital * weights["CC"])
            sub["CC"] = bt.covered_call()
        if weights["CSP"] > 0:
            bt = WeeklyBacktester(self.prices, self.dates, self.capital * weights["CSP"])
            sub["CSP"] = bt.cash_secured_put()
        if weights["IC"] > 0:
            bt = WeeklyBacktester(self.prices, self.dates, self.capital * weights["IC"])
            sub["IC"] = bt.iron_condor()
        if weights["BCS"] > 0:
            bt = WeeklyBacktester(self.prices, self.dates, self.capital * weights["BCS"])
            sub["BCS"] = bt.bull_call_spread()
        if weights["STR"] > 0:
            bt = WeeklyBacktester(self.prices, self.dates, self.capital * weights["STR"])
            sub["STR"] = bt.straddle()

        # Combine weekly PnLs
        nav = self.capital
        results = []
        for w in range(self.n_weeks):
            weekly_pnl = 0
            for name, sr in sub.items():
                if w < len(sr['epochs']):
                    weekly_pnl += sr['epochs'][w]['total_pnl']

            results.append({
                'week': w,
                'date': self.dates[w],
                'entry': self.prices[w],
                'exit': self.prices[w + 1],
                'strike': 0,
                'premium': 0,
                'option_pnl': weekly_pnl,
                'hedge_pnl': 0,
                'total_pnl': weekly_pnl,
                'nav_before': nav,
                'vol': self.weekly_vol[w] if w < len(self.weekly_vol) else 0,
                'delta': 0,
            })
            nav += weekly_pnl

        return self._build_report(f"AutoVault ({tier})", results, nav)

    # =========================================================================
    #                    HEDGE SIMULATION
    # =========================================================================

    def _simulate_hedge(self, week_idx: int, init_delta: float,
                        notional: float, n_rehedge: int = 3) -> float:
        """
        주간 내 delta hedge PnL 시뮬레이션.
        Daily prices를 사용해 discrete rehedging.
        """
        start_day = week_idx * 7
        end_day = min(start_day + 7, len(self.daily) - 1)
        if start_day >= len(self.daily) - 1:
            return 0

        daily_slice = self.daily[start_day:end_day + 1]
        if len(daily_slice) < 2:
            return 0

        S0 = daily_slice[0]
        if S0 <= 0:
            return 0

        hedge_size = init_delta * notional / S0
        total_pnl = 0.0
        step = max(1, len(daily_slice) // (n_rehedge + 1))

        prev_price = daily_slice[0]
        for i in range(step, len(daily_slice), step):
            price = daily_slice[min(i, len(daily_slice) - 1)]
            total_pnl += hedge_size * (price - prev_price)
            prev_price = price
            # Rehedge at current price
            hedge_size = init_delta * notional / price if price > 0 else 0

        # Final segment
        total_pnl += hedge_size * (daily_slice[-1] - prev_price)

        # Slippage: 0.05% per rehedge on HyperCore
        slippage = notional * 0.0005 * n_rehedge
        return total_pnl - slippage

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
        cum_rets = np.cumprod(1 + rets)
        peak = np.maximum.accumulate(cum_rets)
        drawdowns = (peak - cum_rets) / peak
        max_dd = np.max(drawdowns) if len(drawdowns) > 0 else 0

        total_return = (final_nav - self.capital) / self.capital
        ann_return = (1 + total_return) ** (52 / len(results)) - 1 if len(results) > 0 and total_return > -1 else total_return
        sharpe = (np.mean(rets) / np.std(rets)) * np.sqrt(52) if np.std(rets) > 0 else 0
        win_rate = np.mean(np.array(pnls) > 0)

        return {
            'name': name,
            'initial_capital': self.capital,
            'final_nav': final_nav,
            'total_return': total_return,
            'annualized_return': ann_return,
            'sharpe': sharpe,
            'max_drawdown': max_dd,
            'win_rate': win_rate,
            'n_epochs': len(results),
            'avg_pnl': np.mean(pnls),
            'best_epoch': max(pnls),
            'worst_epoch': min(pnls),
            'pnl_std': np.std(pnls),
            'epochs': results,
            'weekly_returns': rets,
            'cumulative': cum_rets,
        }


# =============================================================================
#                          PRINTING
# =============================================================================

def fmt_pct(x): return f"{x*100:+.2f}%"
def fmt_usd(x): return f"${x:,.0f}"
def fmt_apr(x): return f"{x*10000:.0f} bps"


def print_report(r: dict):
    print(f"\n{'='*70}")
    print(f"  {r['name']}")
    print(f"{'='*70}")
    print(f"  초기 자본:        {fmt_usd(r['initial_capital'])}")
    print(f"  최종 NAV:         {fmt_usd(r['final_nav'])}")
    print(f"  총 수익률:        {fmt_pct(r['total_return'])}")
    print(f"  연환산 수익률:    {fmt_pct(r['annualized_return'])}")
    print(f"  APR (bps):        {fmt_apr(r['annualized_return'])}")
    print(f"  Sharpe Ratio:     {r['sharpe']:.2f}")
    print(f"  Max Drawdown:     {fmt_pct(r['max_drawdown'])}")
    print(f"  Win Rate:         {fmt_pct(r['win_rate'])}")
    print(f"  에포크 수:        {r['n_epochs']}주")
    print(f"  평균 주간 PnL:    {fmt_usd(r['avg_pnl'])}")
    print(f"  최고 주간 PnL:    {fmt_usd(r['best_epoch'])}")
    print(f"  최저 주간 PnL:    {fmt_usd(r['worst_epoch'])}")
    print(f"  PnL 표준편차:     {fmt_usd(r['pnl_std'])}")


def print_epoch_table(r: dict, show_all: bool = False):
    epochs = r['epochs']
    n = len(epochs) if show_all else min(len(epochs), 52)

    print(f"\n  {'주':>3} {'날짜':>12} {'ETH시가':>8} {'ETH종가':>8} {'행사가':>8} "
          f"{'프리미엄':>10} {'옵션PnL':>10} {'헤지PnL':>10} {'총PnL':>10} {'NAV':>12} {'Vol':>6}")
    print(f"  {'-'*114}")

    for e in epochs[:n]:
        print(f"  {e['week']:>3} {e['date']:>12} {e['entry']:>8,.0f} {e['exit']:>8,.0f} {e['strike']:>8,.0f} "
              f"{e['premium']:>10,.0f} {e['option_pnl']:>10,.0f} {e['hedge_pnl']:>10,.0f} "
              f"{e['total_pnl']:>10,.0f} {e['nav_before']+e['total_pnl']:>12,.0f} {e['vol']:>5.0%}")


def print_comparison(results: list[dict]):
    print(f"\n{'='*110}")
    print(f"  전략 비교 — 52주 주간 에포크 백테스트 (2025-04 ~ 2026-03)")
    print(f"{'='*110}")

    header = (f"  {'전략':<25} {'총수익률':>10} {'연환산APR':>10} {'Sharpe':>8} "
              f"{'MaxDD':>10} {'WinRate':>10} {'최종NAV':>14}")
    print(header)
    print(f"  {'-'*100}")

    for r in results:
        print(f"  {r['name']:<25} "
              f"{fmt_pct(r['total_return']):>10} "
              f"{fmt_pct(r['annualized_return']):>10} "
              f"{r['sharpe']:>8.2f} "
              f"{fmt_pct(r['max_drawdown']):>10} "
              f"{fmt_pct(r['win_rate']):>10} "
              f"{fmt_usd(r['final_nav']):>14}")


def print_fee_analysis(results: list[dict]):
    print(f"\n{'='*110}")
    print(f"  프로토콜 수수료 분석 (Performance 15% + Management 1.5% + Early Exit 0.5%)")
    print(f"{'='*110}")

    PF, MF = 0.15, 0.015
    header = (f"  {'전략':<25} {'총수익':>12} {'성과보수':>12} {'운용보수':>12} "
              f"{'LP순수익':>14} {'프로토콜수익':>14}")
    print(header)
    print(f"  {'-'*100}")

    total_rev = 0
    for r in results:
        gross = max(r['final_nav'] - r['initial_capital'], 0)
        perf = gross * PF
        mgmt = r['initial_capital'] * MF * (r['n_epochs'] / 52)
        total_fees = perf + mgmt
        net = r['final_nav'] - total_fees
        total_rev += total_fees

        print(f"  {r['name']:<25} "
              f"{fmt_usd(gross):>12} "
              f"{fmt_usd(perf):>12} "
              f"{fmt_usd(mgmt):>12} "
              f"{fmt_usd(net):>14} "
              f"{fmt_usd(total_fees):>14}")

    print(f"  {'-'*100}")
    print(f"  {'총 프로토콜 수익':<25} {'':>12} {'':>12} {'':>12} {'':>14} {fmt_usd(total_rev):>14}")


# =============================================================================
#                            MAIN
# =============================================================================

def main():
    print("\n" + "="*70)
    print("  NOMAD FINANCE — 주간 에포크 백테스트")
    print("  기간: 2024-04-01 ~ 2025-03-31 (52주, 실제 과거 데이터)")
    print("  기초자산: ETH/USD")
    print("  에포크: 7일 (매주 월요일 roll)")
    print("  초기자본: $1,000,000")
    print("="*70)

    prices = ETH_WEEKLY_CLOSE
    print(f"\n  ETH 가격 범위: ${prices.min():,.0f} — ${prices.max():,.0f}")
    print(f"  시작: ${prices[0]:,.0f} → 종료: ${prices[-1]:,.0f} ({(prices[-1]/prices[0]-1)*100:+.1f}%)")

    weekly_rets = get_weekly_returns(prices)
    realized_vol = np.std(weekly_rets) * np.sqrt(52)
    print(f"  실현 변동성: {realized_vol:.1%} (연환산)")
    print(f"  주간 수익률 범위: {weekly_rets.min()*100:+.1f}% ~ {weekly_rets.max()*100:+.1f}%")

    bt = WeeklyBacktester(prices, WEEK_DATES, capital=1_000_000)

    # --- 개별 전략 ---
    print("\n\n" + "#"*70)
    print("  PART 1: 개별 전략 백테스트 (52주)")
    print("#"*70)

    cc = bt.covered_call(target_delta=0.25)
    csp = bt.cash_secured_put(target_delta=0.25)
    ic = bt.iron_condor(short_delta=0.20, spread_pct=0.05)
    bcs = bt.bull_call_spread(long_delta=0.55, short_delta=0.25)
    strad = bt.straddle()

    individual = [cc, csp, ic, bcs, strad]

    for r in individual:
        print_report(r)

    print_comparison(individual)

    # --- 에포크별 상세 (CC 기준) ---
    print("\n\n" + "#"*70)
    print("  PART 2: CoveredCall 주간 에포크 상세")
    print("#"*70)
    print_epoch_table(cc, show_all=True)

    # --- AutoVault ---
    print("\n\n" + "#"*70)
    print("  PART 3: AutoVault 리스크 티어별 비교")
    print("#"*70)

    auto_c = bt.auto_vault("conservative")
    auto_m = bt.auto_vault("moderate")
    auto_a = bt.auto_vault("aggressive")

    auto_results = [auto_c, auto_m, auto_a]
    for r in auto_results:
        print_report(r)

    print_comparison(auto_results)

    # --- 수수료 분석 ---
    print("\n\n" + "#"*70)
    print("  PART 4: 프로토콜 수수료 수익 분석")
    print("#"*70)

    print_fee_analysis(individual + [auto_m])

    # --- 리스크 분석 ---
    print("\n\n" + "#"*70)
    print("  PART 5: 리스크 분석")
    print("#"*70)

    print(f"\n  {'전략':<25} {'최대연속손실':>10} {'Sortino':>8} {'Calmar':>8} {'주간VaR(95%)':>14}")
    print(f"  {'-'*75}")

    for r in individual + auto_results:
        rets = r['weekly_returns']
        # Max consecutive losses
        max_consec = 0
        consec = 0
        for ret in rets:
            if ret < 0:
                consec += 1
                max_consec = max(max_consec, consec)
            else:
                consec = 0

        # Sortino ratio
        neg_rets = rets[rets < 0]
        downside_std = np.std(neg_rets) if len(neg_rets) > 0 else 1e-10
        sortino = (np.mean(rets) / downside_std) * np.sqrt(52) if downside_std > 0 else 0

        # Calmar ratio
        calmar = r['annualized_return'] / r['max_drawdown'] if r['max_drawdown'] > 0 else 0

        # VaR 95%
        var_95 = np.percentile(rets, 5) if len(rets) > 0 else 0

        print(f"  {r['name']:<25} {max_consec:>10}주 {sortino:>8.2f} {calmar:>8.2f} {fmt_pct(var_95):>14}")

    # --- 요약 ---
    print("\n\n" + "="*70)
    print("  백테스트 완료")
    print("="*70)
    print(f"  기간: {WEEK_DATES[0]} ~ {WEEK_DATES[-1]}")
    print(f"  에포크: 51주 × 8전략 = {51 * 8} 에포크 시뮬레이션")
    print(f"  ETH 변동: ${prices[0]:,.0f} → ${prices[-1]:,.0f} ({(prices[-1]/prices[0]-1)*100:+.1f}%)")
    print(f"  실현 Vol: {realized_vol:.1%}")
    print()

    # Target APR check
    print(f"  Phase 1 타겟 APR 20-55% 달성 여부:")
    for r in [cc, csp]:
        apr = r['annualized_return'] * 100
        status = "✓" if 20 <= apr <= 55 else ("△ 초과" if apr > 55 else "✗ 미달")
        print(f"    {r['name']:<20} {apr:+.1f}% {status}")

    print(f"\n  AutoVault Moderate 목표:")
    apr_m = auto_m['annualized_return'] * 100
    sr_m = auto_m['sharpe']
    dd_m = auto_m['max_drawdown'] * 100
    print(f"    APR: {apr_m:+.1f}% (목표 20-55%)")
    print(f"    Sharpe: {sr_m:.2f} (목표 >1.0)")
    print(f"    Max DD: {dd_m:.1f}% (목표 <15%)")
    print()


if __name__ == "__main__":
    main()
