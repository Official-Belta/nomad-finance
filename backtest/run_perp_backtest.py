#!/usr/bin/env python3
"""
Nomad Finance — Perp-Only Strategy Backtest
=============================================
4 strategies on HyperCore perps, regime-aware allocation.
Strategies: FundingRateArb, TrendFollowing, MeanReversion, VolBreakout
"""

import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
from eth_weekly_prices import ETH_WEEKLY_CLOSE, WEEK_DATES, get_daily_prices_from_weekly, get_weekly_returns
from funding_rates import generate_funding_rates, weekly_funding_summary
from regime import Regime, classify_all_weeks
from pricing import ewma_vol


# =============================================================================
#                     PERP STRATEGY SIMULATORS
# =============================================================================

class PerpBacktester:
    """Perp-only strategy backtester with regime-aware allocation."""

    # Risk params
    MAX_LOSS_PER_EPOCH = 0.05   # 5% of NAV max loss per epoch
    STOP_LOSS = 0.07            # 7% stop-loss
    TRADING_FEE = 0.0003        # 3bps per trade (taker)
    MAX_LEVERAGE = 2.0          # max 2x leverage

    # Regime weights: FRA, TF, MR, VB, cash
    REGIME_WEIGHTS = {
        Regime.BULL_TREND:        {"FRA": 0.30, "TF": 0.50, "MR": 0.00, "VB": 0.10},
        Regime.BEAR_TREND:        {"FRA": 0.10, "TF": 0.40, "MR": 0.00, "VB": 0.10},
        Regime.HIGH_VOL_SIDEWAYS: {"FRA": 0.40, "TF": 0.00, "MR": 0.30, "VB": 0.15},
        Regime.LOW_VOL_SIDEWAYS:  {"FRA": 0.50, "TF": 0.00, "MR": 0.25, "VB": 0.10},
    }

    def __init__(self, weekly_prices, week_dates, capital=1_000_000):
        self.prices = weekly_prices
        self.dates = week_dates
        self.capital = capital
        self.n_weeks = len(weekly_prices) - 1
        self.daily = get_daily_prices_from_weekly(weekly_prices)
        self.weekly_rets = get_weekly_returns(weekly_prices)
        self.regimes = classify_all_weeks(weekly_prices)
        self.funding = generate_funding_rates(weekly_prices)
        self.weekly_vol = self._calc_vol()

    def _calc_vol(self):
        rets = self.weekly_rets
        vols = np.zeros(len(rets))
        for i in range(len(rets)):
            lb = max(0, i - 3)
            w = rets[lb:i+1]
            vols[i] = np.std(w) * np.sqrt(52) if len(w) > 1 else 0.70
        return np.clip(vols, 0.30, 2.00)

    # =========================================================================
    #  Strategy 1: Funding Rate Arbitrage
    # =========================================================================
    def funding_rate_arb(self, w, nav):
        """Short perp when funding positive, collect funding. Close if negative."""
        S = self.prices[w]
        rates = self.funding[w]  # 21 intervals
        avg_rate = np.mean(rates)

        # Only enter if avg funding > threshold (0.005% per 8h)
        if avg_rate < 0.00005:
            return {"total_pnl": 0, "detail": "skip: low funding"}

        # Position size: deploy up to 60% of nav, capped by leverage
        sigma = self.weekly_vol[w] if w < len(self.weekly_vol) else 0.70
        pos_size = nav * 0.6  # 60% utilization for funding arb

        # Funding PnL: short perp collects positive funding
        funding_pnl = pos_size * np.sum(rates)  # sum of 21 intervals

        # Price PnL: FRA is delta-neutral! We hold spot equivalent + short perp.
        # The spot leg offsets the perp price movement.
        # Net price PnL ≈ 0 (delta neutral), only funding remains.
        # In practice there's basis risk and rebalancing cost.
        S_end = self.prices[w + 1]
        basis_slippage = pos_size * abs(S_end - S) / S * 0.05  # 5% of move as basis risk

        # Stop-loss: if basis diverges too much (extreme move > 15% in a week)
        start_day = w * 7
        stopped = False
        for d in range(1, 8):
            idx = start_day + d
            if idx >= len(self.daily):
                break
            move = abs(self.daily[idx] - S) / S
            if move > 0.15:  # >15% move causes margin stress
                basis_slippage = pos_size * move * 0.10  # 10% of move leaked
                funding_pnl = pos_size * np.sum(rates[:d*3])  # partial funding
                stopped = True
                break

        # Trading fees (entry + exit) + rebalancing
        fees = pos_size * self.TRADING_FEE * 2
        rebal_cost = pos_size * 0.0005  # 5bps rebalancing cost per week

        total = funding_pnl - basis_slippage - fees - rebal_cost
        return {"total_pnl": total, "funding": funding_pnl, "price": -basis_slippage, "fees": fees}

    # =========================================================================
    #  Strategy 2: Trend Following
    # =========================================================================
    def trend_following(self, w, nav):
        """Long in bull, short in bear, flat in sideways."""
        regime = self.regimes[w] if w < len(self.regimes) else Regime.LOW_VOL_SIDEWAYS

        if regime not in (Regime.BULL_TREND, Regime.BEAR_TREND):
            return {"total_pnl": 0, "detail": "skip: sideways"}

        S = self.prices[w]
        S_end = self.prices[w + 1]
        sigma = self.weekly_vol[w] if w < len(self.weekly_vol) else 0.70

        is_long = regime == Regime.BULL_TREND
        direction = 1 if is_long else -1

        # Position size: 30% of nav for trend following
        pos_size = nav * 0.30

        # Price PnL
        ret = (S_end - S) / S
        price_pnl = pos_size * ret * direction

        # Trailing stop check on daily prices
        start_day = w * 7
        peak_pnl = 0
        final_pnl = price_pnl
        stopped = False

        for d in range(1, 8):
            idx = start_day + d
            if idx >= len(self.daily):
                break
            daily_ret = (self.daily[idx] - S) / S * direction
            daily_pnl = pos_size * daily_ret
            peak_pnl = max(peak_pnl, daily_pnl)

            # Trailing stop: 5% from peak or 5% absolute loss
            if daily_pnl < peak_pnl - nav * 0.03 or daily_pnl < -nav * self.STOP_LOSS:
                final_pnl = daily_pnl
                stopped = True
                break

        # Funding (long pays, short collects — on average)
        avg_funding = np.mean(self.funding[w])
        funding_impact = -pos_size * avg_funding * 21 * direction  # long pays, short collects

        fees = pos_size * self.TRADING_FEE * 2
        total = final_pnl + funding_impact - fees

        return {"total_pnl": total, "price": final_pnl, "funding": funding_impact,
                "fees": fees, "stopped": stopped}

    # =========================================================================
    #  Strategy 3: Mean Reversion
    # =========================================================================
    def mean_reversion(self, w, nav):
        """Counter-trend in sideways regimes. Z-score based entry."""
        regime = self.regimes[w] if w < len(self.regimes) else Regime.LOW_VOL_SIDEWAYS

        if regime not in (Regime.HIGH_VOL_SIDEWAYS, Regime.LOW_VOL_SIDEWAYS):
            return {"total_pnl": 0, "detail": "skip: trending"}

        # Z-score of recent returns
        lookback = min(w, 4)
        if lookback < 2:
            return {"total_pnl": 0, "detail": "skip: insufficient data"}

        recent_rets = self.weekly_rets[max(0,w-lookback):w]
        z = (self.weekly_rets[w-1] - np.mean(recent_rets)) / max(np.std(recent_rets), 0.01) if len(recent_rets) > 1 else 0

        # Entry: counter-trend when z-score is extreme
        if abs(z) < 1.0:
            return {"total_pnl": 0, "detail": "skip: no signal"}

        S = self.prices[w]
        S_end = self.prices[w + 1]
        sigma = self.weekly_vol[w] if w < len(self.weekly_vol) else 0.70

        # Short if z > 1 (overbought), long if z < -1 (oversold)
        direction = -1 if z > 0 else 1

        # Mean reversion: 15% of nav
        pos_size = nav * 0.15

        # Price PnL with tight stop
        ret = (S_end - S) / S
        price_pnl = pos_size * ret * direction

        # Tight stop-loss: 3% of position
        start_day = w * 7
        for d in range(1, 8):
            idx = start_day + d
            if idx >= len(self.daily):
                break
            daily_ret = (self.daily[idx] - S) / S * direction
            daily_pnl = pos_size * daily_ret
            if daily_pnl < -pos_size * 0.03:  # 3% stop
                price_pnl = daily_pnl
                break
            # Take profit at 2%
            if daily_pnl > pos_size * 0.02:
                price_pnl = daily_pnl
                break

        fees = pos_size * self.TRADING_FEE * 2
        return {"total_pnl": price_pnl - fees, "price": price_pnl, "fees": fees, "z": z}

    # =========================================================================
    #  Strategy 4: Volatility Breakout
    # =========================================================================
    def vol_breakout(self, w, nav):
        """Enter on vol expansion in breakout direction."""
        if w < 4:
            return {"total_pnl": 0, "detail": "skip: warmup"}

        S = self.prices[w]
        S_end = self.prices[w + 1]

        # Vol squeeze detection: current vol < 70% of 8-week average
        recent_vols = self.weekly_vol[max(0,w-8):w]
        avg_vol = np.mean(recent_vols) if len(recent_vols) > 0 else 0.70
        curr_vol = self.weekly_vol[w] if w < len(self.weekly_vol) else 0.70

        # Check for squeeze
        is_squeeze = curr_vol < avg_vol * 0.70

        # Check for breakout: large move in current week relative to recent range
        recent_prices = self.prices[max(0,w-4):w+1]
        price_range = np.max(recent_prices) - np.min(recent_prices)
        week_move = abs(S_end - S)

        is_breakout = week_move > price_range * 0.5 if price_range > 0 else False

        if not (is_squeeze or is_breakout):
            return {"total_pnl": 0, "detail": "skip: no breakout"}

        # Direction: follow the breakout
        direction = 1 if S_end > S else -1

        # But we need to decide at entry... use momentum of last 2 days
        start_day = w * 7
        mid_idx = min(start_day + 3, len(self.daily) - 1)
        mid_price = self.daily[mid_idx]
        entry_direction = 1 if mid_price > S else -1

        sigma = self.weekly_vol[w] if w < len(self.weekly_vol) else 0.70
        pos_size = nav * 0.15  # 15% of nav for vol breakout

        # Simulate from mid-week entry
        ret = (S_end - mid_price) / mid_price * entry_direction
        price_pnl = pos_size * ret

        # Stop-loss
        for d in range(4, 8):
            idx = start_day + d
            if idx >= len(self.daily):
                break
            daily_ret = (self.daily[idx] - mid_price) / mid_price * entry_direction
            daily_pnl = pos_size * daily_ret
            if daily_pnl < -pos_size * 0.04:
                price_pnl = daily_pnl
                break

        fees = pos_size * self.TRADING_FEE * 2
        return {"total_pnl": price_pnl - fees, "price": price_pnl, "fees": fees}

    # =========================================================================
    #  Full strategy runs
    # =========================================================================
    def run_single(self, name, fn):
        nav = self.capital
        results = []
        for w in range(self.n_weeks):
            res = fn(w, nav)
            pnl = res["total_pnl"]
            results.append({
                "week": w, "date": self.dates[w],
                "entry": self.prices[w], "exit": self.prices[w+1],
                "total_pnl": pnl, "nav_before": nav,
                "regime": self.regimes[w].value if w < len(self.regimes) else "",
            })
            nav += pnl
        return self._report(name, results, nav)

    def run_auto_vault(self, mode="dynamic"):
        """Run multi-strategy with regime-based allocation."""
        nav = self.capital
        results = []
        strats = {
            "FRA": self.funding_rate_arb,
            "TF": self.trend_following,
            "MR": self.mean_reversion,
            "VB": self.vol_breakout,
        }

        # Static tier weights for comparison
        STATIC = {
            "conservative": {"FRA": 0.60, "TF": 0.00, "MR": 0.15, "VB": 0.00},
            "moderate":     {"FRA": 0.40, "TF": 0.25, "MR": 0.15, "VB": 0.10},
            "aggressive":   {"FRA": 0.30, "TF": 0.30, "MR": 0.15, "VB": 0.15},
        }

        for w in range(self.n_weeks):
            regime = self.regimes[w] if w < len(self.regimes) else Regime.LOW_VOL_SIDEWAYS

            if mode == "dynamic":
                weights = self.REGIME_WEIGHTS.get(regime, self.REGIME_WEIGHTS[Regime.LOW_VOL_SIDEWAYS])
            else:
                weights = STATIC.get(mode, STATIC["moderate"])

            epoch_pnl = 0
            for sname, weight in weights.items():
                if weight <= 0:
                    continue
                alloc = nav * weight
                res = strats[sname](w, alloc)
                epoch_pnl += res["total_pnl"]

            results.append({
                "week": w, "date": self.dates[w],
                "entry": self.prices[w], "exit": self.prices[w+1],
                "total_pnl": epoch_pnl, "nav_before": nav,
                "regime": regime.value,
            })
            nav += epoch_pnl

        label = "PerpVault (dynamic)" if mode == "dynamic" else f"PerpVault ({mode})"
        return self._report(label, results, nav)

    # =========================================================================
    #  Reporting
    # =========================================================================
    def _report(self, name, results, final_nav):
        pnls = [r["total_pnl"] for r in results]
        nav = self.capital
        rets = []
        for p in pnls:
            rets.append(p / nav if nav > 0 else 0)
            nav += p
        rets = np.array(rets)
        cum = np.cumprod(1 + rets)
        peak = np.maximum.accumulate(cum)
        dd = (peak - cum) / peak
        max_dd = float(np.max(dd)) if len(dd) > 0 else 0
        total_ret = (final_nav - self.capital) / self.capital
        n = len(results)
        ann = (1+total_ret)**(52/n)-1 if n > 0 and total_ret > -1 else total_ret
        sharpe = float(np.mean(rets)/np.std(rets)*np.sqrt(52)) if np.std(rets) > 0 else 0
        wr = float(np.mean(np.array(pnls) > 0))
        return {
            "name": name, "initial_capital": self.capital,
            "final_nav": final_nav, "total_return": total_ret,
            "annualized_return": ann, "sharpe": sharpe,
            "max_drawdown": max_dd, "win_rate": wr,
            "n_epochs": n, "avg_pnl": float(np.mean(pnls)),
            "best_epoch": float(max(pnls)), "worst_epoch": float(min(pnls)),
            "pnl_std": float(np.std(pnls)), "epochs": results,
            "weekly_returns": rets, "cumulative": cum,
        }


# =============================================================================
#                          PRINTING
# =============================================================================

def fmt_pct(x): return f"{x*100:+.2f}%"
def fmt_usd(x): return f"${x:,.0f}"

def print_report(r):
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
    print(f"  최고/최저:        {fmt_usd(r['best_epoch'])} / {fmt_usd(r['worst_epoch'])}")

def print_comparison(results):
    print(f"\n{'='*115}")
    print(f"  전략 비교")
    print(f"{'='*115}")
    h = f"  {'전략':<30} {'수익률':>10} {'APR':>10} {'Sharpe':>8} {'MaxDD':>10} {'WinRate':>10} {'최종NAV':>14}"
    print(h)
    print(f"  {'-'*108}")
    for r in results:
        print(f"  {r['name']:<30} {fmt_pct(r['total_return']):>10} "
              f"{fmt_pct(r['annualized_return']):>10} {r['sharpe']:>8.2f} "
              f"{fmt_pct(r['max_drawdown']):>10} {fmt_pct(r['win_rate']):>10} "
              f"{fmt_usd(r['final_nav']):>14}")

def print_risk(results):
    print(f"\n  {'전략':<30} {'연속손실':>8} {'Sortino':>8} {'Calmar':>8} {'VaR95%':>10}")
    print(f"  {'-'*72}")
    for r in results:
        rets = r['weekly_returns']
        mc = cc = 0
        for ret in rets:
            if ret < 0: cc += 1; mc = max(mc, cc)
            else: cc = 0
        neg = rets[rets < 0]
        ds = float(np.std(neg)) if len(neg) > 0 else 1e-10
        sortino = float(np.mean(rets)/ds*np.sqrt(52)) if ds > 0 else 0
        calmar = r['annualized_return']/r['max_drawdown'] if r['max_drawdown'] > 0 else 0
        var95 = float(np.percentile(rets, 5)) if len(rets) > 0 else 0
        print(f"  {r['name']:<30} {mc:>7}주 {sortino:>8.2f} {calmar:>8.2f} {fmt_pct(var95):>10}")


# =============================================================================
#                            MAIN
# =============================================================================

def main():
    print("\n" + "="*70)
    print("  NOMAD FINANCE — Perp-Only 백테스트")
    print("  기간: 2025-04-06 ~ 2026-03-30 (52주)")
    print("  전략: FundingRateArb, TrendFollowing, MeanReversion, VolBreakout")
    print("  인프라: HyperCore perps only (Rysk 제거)")
    print("="*70)

    prices = ETH_WEEKLY_CLOSE
    print(f"\n  ETH: ${prices[0]:,.0f} → ATH ${prices.max():,.0f} → ${prices[-1]:,.0f}")
    print(f"  52주 범위: ${prices.min():,.0f} — ${prices.max():,.0f}")
    wr = get_weekly_returns(prices)
    print(f"  실현 Vol: {np.std(wr)*np.sqrt(52):.1%}")

    bt = PerpBacktester(prices, WEEK_DATES, capital=1_000_000)

    # Funding rate summary
    from funding_rates import print_funding_summary, annualized_funding_yield
    ann_funding = annualized_funding_yield(bt.funding)
    print(f"  연환산 평균 펀딩비: {ann_funding*100:.1f}%")

    # --- Part 1: Individual strategies ---
    print("\n\n" + "#"*70)
    print("  PART 1: 개별 Perp 전략")
    print("#"*70)

    fra = bt.run_single("FundingRateArb", bt.funding_rate_arb)
    tf = bt.run_single("TrendFollowing", bt.trend_following)
    mr = bt.run_single("MeanReversion", bt.mean_reversion)
    vb = bt.run_single("VolBreakout", bt.vol_breakout)

    individual = [fra, tf, mr, vb]
    for r in individual:
        print_report(r)
    print_comparison(individual)

    # --- Part 2: PerpVault ---
    print("\n\n" + "#"*70)
    print("  PART 2: PerpVault — Static vs Dynamic")
    print("#"*70)

    static_c = bt.run_auto_vault("conservative")
    static_m = bt.run_auto_vault("moderate")
    static_a = bt.run_auto_vault("aggressive")
    dynamic = bt.run_auto_vault("dynamic")

    vault_results = [static_c, static_m, static_a, dynamic]
    for r in vault_results:
        print_report(r)
    print_comparison(vault_results)

    # --- Part 3: Risk ---
    print("\n\n" + "#"*70)
    print("  PART 3: 리스크 분석")
    print("#"*70)
    print_risk(individual + [dynamic])

    # --- Part 4: vs Options v2 ---
    print("\n\n" + "#"*70)
    print("  PART 4: Options v2 vs Perp 비교")
    print("#"*70)

    # Load options v2 results for comparison (re-run key ones)
    from run_weekly_backtest import ImprovedBacktester
    opt_bt = ImprovedBacktester(prices, WEEK_DATES, capital=1_000_000)
    opt_dynamic = opt_bt.auto_vault_dynamic()
    opt_bcs = opt_bt.run_strategy("BCS (options v2)", opt_bt._bcs_one_epoch)

    comparison = [opt_dynamic, opt_bcs, dynamic, fra, tf]
    print_comparison(comparison)

    # --- Summary ---
    print("\n\n" + "="*70)
    print("  백테스트 완료")
    print("="*70)
    best = max(individual + vault_results, key=lambda r: r["annualized_return"])
    print(f"  최고 전략: {best['name']} — {fmt_pct(best['annualized_return'])} APR, Sharpe {best['sharpe']:.2f}")
    print(f"  PerpVault (dynamic): {fmt_pct(dynamic['annualized_return'])} APR, "
          f"Sharpe {dynamic['sharpe']:.2f}, MaxDD {fmt_pct(dynamic['max_drawdown'])}")
    print(f"\n  Perp vs Options AutoVault:")
    print(f"    Options v2 dynamic: {fmt_pct(opt_dynamic['annualized_return'])} APR")
    print(f"    Perp dynamic:       {fmt_pct(dynamic['annualized_return'])} APR")
    print()


if __name__ == "__main__":
    main()
