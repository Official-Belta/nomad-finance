#!/usr/bin/env python3
"""
Nomad Finance — Full Protocol Backtesting Engine
=================================================
Generates synthetic ETH-like price data and runs all 5 strategies + AutoVault.
Outputs performance metrics and epoch-by-epoch analysis.

Usage: python3 run_backtest.py
"""

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
import pandas as pd
from datetime import datetime, timedelta

from pricing import ewma_vol
from strategies import (
    backtest_covered_call,
    backtest_cash_secured_put,
    backtest_iron_condor,
    backtest_bull_call_spread,
    backtest_straddle,
    backtest_auto_vault,
    BacktestResult,
)


# =============================================================================
#                     SYNTHETIC PRICE GENERATION
# =============================================================================

def generate_eth_prices(
    n_days: int = 365,
    start_price: float = 3000.0,
    annual_drift: float = 0.0,    # neutral drift for fair backtest
    base_vol: float = 0.75,       # ~75% annualized vol (crypto-typical)
    vol_of_vol: float = 0.30,     # stochastic vol clustering
    jump_prob: float = 0.02,      # 2% daily jump probability
    jump_size: float = 0.08,      # 8% average jump magnitude
    seed: int = 42,
) -> tuple[np.ndarray, np.ndarray]:
    """
    Generate realistic ETH-like daily prices with:
    - GBM base dynamics
    - Stochastic volatility (mean-reverting)
    - Jump diffusion (fat tails)
    - Vol clustering (high vol follows high vol)

    Returns (prices, daily_returns) arrays.
    """
    rng = np.random.default_rng(seed)

    dt = 1 / 365.25
    prices = np.zeros(n_days)
    prices[0] = start_price
    returns = np.zeros(n_days)
    vol = base_vol

    for i in range(1, n_days):
        # Mean-reverting vol: dσ = κ(θ - σ)dt + ξσ dW
        kappa = 5.0   # speed of mean reversion
        xi = vol_of_vol
        vol += kappa * (base_vol - vol) * dt + xi * vol * rng.normal() * np.sqrt(dt)
        vol = max(0.20, min(vol, 2.0))  # clamp [20%, 200%]

        # GBM with stochastic vol
        z = rng.normal()
        ret = (annual_drift - 0.5 * vol**2) * dt + vol * np.sqrt(dt) * z

        # Jump component
        if rng.random() < jump_prob:
            jump = rng.normal(0, jump_size)
            ret += jump

        returns[i] = ret
        prices[i] = prices[i - 1] * np.exp(ret)

    return prices, returns


def generate_multi_regime_prices(
    n_days: int = 730,  # 2 years
    start_price: float = 3000.0,
    seed: int = 42,
) -> tuple[np.ndarray, np.ndarray]:
    """
    Generate price path with multiple market regimes:
    1. Bull market (low vol rally)
    2. Consolidation (range-bound)
    3. Crash (high vol sharp drop)
    4. Recovery (gradual climb)
    5. Volatile sideways
    """
    rng = np.random.default_rng(seed)
    dt = 1 / 365.25

    # Define regimes: (duration_days, drift, vol)
    regimes = [
        (120, 0.80, 0.50),    # Bull: +80% drift, 50% vol
        (90, 0.0, 0.40),      # Consolidation: flat, 40% vol
        (30, -3.0, 1.50),     # Crash: sharp drop, 150% vol
        (60, -0.5, 1.20),     # Continued bearish, 120% vol
        (90, 0.60, 0.60),     # Recovery: +60% drift, 60% vol
        (120, 0.30, 0.70),    # Volatile sideways: mild up, 70% vol
        (100, 0.50, 0.55),    # Late bull: +50% drift, 55% vol
        (120, -0.10, 0.80),   # Choppy: slight down, 80% vol
    ]

    prices = [start_price]
    returns = [0.0]

    for duration, drift, vol in regimes:
        for _ in range(duration):
            if len(prices) >= n_days:
                break
            z = rng.normal()
            ret = (drift - 0.5 * vol**2) * dt + vol * np.sqrt(dt) * z
            # Occasional jumps
            if rng.random() < 0.015:
                ret += rng.normal(0, 0.06)
            returns.append(ret)
            prices.append(prices[-1] * np.exp(ret))

    return np.array(prices[:n_days]), np.array(returns[:n_days])


# =============================================================================
#                         REPORTING
# =============================================================================

def format_pct(x: float) -> str:
    return f"{x * 100:+.2f}%"


def format_usd(x: float) -> str:
    return f"${x:,.0f}"


def print_result(r: BacktestResult, verbose: bool = False):
    """Print formatted backtest results."""
    print(f"\n{'='*60}")
    print(f"  {r.strategy_name}")
    print(f"{'='*60}")
    print(f"  Initial Capital:    {format_usd(r.initial_capital)}")
    print(f"  Final Capital:      {format_usd(r.final_capital)}")
    print(f"  Total Return:       {format_pct(r.total_return)}")
    print(f"  Annualized Return:  {format_pct(r.annualized_return)}")
    print(f"  APR (bps):          {r.annualized_return * 10000:.0f}")
    print(f"  Sharpe Ratio:       {r.sharpe_ratio:.2f}")
    print(f"  Max Drawdown:       {format_pct(r.max_drawdown)}")
    print(f"  Win Rate:           {format_pct(r.win_rate)}")
    print(f"  # Epochs:           {len(r.epochs)}")

    if r.epochs:
        pnls = [e.total_pnl for e in r.epochs]
        print(f"  Avg Epoch PnL:      {format_usd(np.mean(pnls))}")
        print(f"  Best Epoch:         {format_usd(max(pnls))}")
        print(f"  Worst Epoch:        {format_usd(min(pnls))}")
        print(f"  PnL Std Dev:        {format_usd(np.std(pnls))}")

    if verbose and r.epochs:
        print(f"\n  {'Epoch':>5} {'Entry':>8} {'Exit':>8} {'Strike':>8} {'Premium':>10} {'OptPnL':>10} {'HedgePnL':>10} {'Total':>10} {'Vol':>6}")
        print(f"  {'-'*86}")
        for e in r.epochs[:20]:  # first 20
            print(f"  {e.epoch:>5} {e.entry_price:>8.0f} {e.exit_price:>8.0f} {e.strike:>8.0f} "
                  f"{e.premium:>10.0f} {e.intrinsic_pnl:>10.0f} {e.hedge_pnl:>10.0f} "
                  f"{e.total_pnl:>10.0f} {e.vol_used:>5.0%}")
        if len(r.epochs) > 20:
            print(f"  ... ({len(r.epochs) - 20} more epochs)")


def print_comparison_table(results: list[BacktestResult]):
    """Print side-by-side comparison of all strategies."""
    print(f"\n{'='*100}")
    print(f"  STRATEGY COMPARISON")
    print(f"{'='*100}")

    header = f"  {'Strategy':<25} {'Return':>10} {'APR':>10} {'Sharpe':>8} {'MaxDD':>10} {'WinRate':>10} {'Final NAV':>14}"
    print(header)
    print(f"  {'-'*95}")

    for r in results:
        print(f"  {r.strategy_name:<25} "
              f"{format_pct(r.total_return):>10} "
              f"{format_pct(r.annualized_return):>10} "
              f"{r.sharpe_ratio:>8.2f} "
              f"{format_pct(r.max_drawdown):>10} "
              f"{format_pct(r.win_rate):>10} "
              f"{format_usd(r.final_capital):>14}")


def print_fee_analysis(results: list[BacktestResult]):
    """Simulate protocol fee revenue."""
    print(f"\n{'='*100}")
    print(f"  PROTOCOL FEE ANALYSIS")
    print(f"{'='*100}")

    PERF_FEE = 0.15      # 15%
    MGMT_FEE = 0.015     # 1.5% annual
    EARLY_EXIT = 0.005   # 0.5%

    header = f"  {'Strategy':<25} {'Gross Profit':>14} {'Perf Fee':>12} {'Mgmt Fee':>12} {'Net to LPs':>14} {'Fee Rev':>12}"
    print(header)
    print(f"  {'-'*95}")

    total_fee_rev = 0
    for r in results:
        gross_profit = max(r.final_capital - r.initial_capital, 0)
        perf_fee = gross_profit * PERF_FEE
        n_years = len(r.epochs) * 7 / 365.25
        mgmt_fee = r.initial_capital * MGMT_FEE * n_years
        total_fees = perf_fee + mgmt_fee
        net_to_lps = r.final_capital - total_fees

        total_fee_rev += total_fees

        print(f"  {r.strategy_name:<25} "
              f"{format_usd(gross_profit):>14} "
              f"{format_usd(perf_fee):>12} "
              f"{format_usd(mgmt_fee):>12} "
              f"{format_usd(net_to_lps):>14} "
              f"{format_usd(total_fees):>12}")

    print(f"  {'-'*95}")
    print(f"  {'TOTAL PROTOCOL REVENUE':<25} {'':>14} {'':>12} {'':>12} {'':>14} {format_usd(total_fee_rev):>12}")


# =============================================================================
#                            MAIN
# =============================================================================

def main():
    print("\n" + "="*60)
    print("  NOMAD FINANCE — BACKTEST ENGINE v1.0")
    print("  Options Strategy Protocol on Hyperliquid")
    print("="*60)

    CAPITAL = 1_000_000  # $1M

    # --- Scenario 1: Single regime (1 year, neutral) ---
    print("\n\n" + "#"*60)
    print("  SCENARIO 1: Neutral Market (1 Year, GBM + Jumps)")
    print("#"*60)

    prices_1y, returns_1y = generate_eth_prices(
        n_days=365, start_price=3000, annual_drift=0.0,
        base_vol=0.75, seed=42
    )
    vol_1y = ewma_vol(returns_1y)

    print(f"\n  Price range: ${prices_1y.min():.0f} — ${prices_1y.max():.0f}")
    print(f"  Start: ${prices_1y[0]:.0f} → End: ${prices_1y[-1]:.0f} ({(prices_1y[-1]/prices_1y[0]-1)*100:+.1f}%)")
    print(f"  Realized vol: {np.std(returns_1y[1:]) * np.sqrt(365.25):.1%}")

    results_1y = [
        backtest_covered_call(prices_1y, 7, 0.25, CAPITAL, vol_1y),
        backtest_cash_secured_put(prices_1y, 7, 0.25, CAPITAL, vol_1y),
        backtest_iron_condor(prices_1y, 7, 0.20, 0.05, CAPITAL, vol_1y),
        backtest_bull_call_spread(prices_1y, 14, 0.55, 0.25, CAPITAL, vol_1y),
        backtest_straddle(prices_1y, 7, CAPITAL, vol_1y),
    ]

    for r in results_1y:
        print_result(r)
    print_comparison_table(results_1y)

    # --- AutoVault scenarios ---
    print("\n\n" + "#"*60)
    print("  AUTO VAULT — RISK TIER COMPARISON (1 Year, Neutral)")
    print("#"*60)

    auto_results = []
    for tier in ["conservative", "moderate", "aggressive"]:
        r = backtest_auto_vault(prices_1y, 7, CAPITAL, vol_1y, tier)
        auto_results.append(r)
        print_result(r)
    print_comparison_table(auto_results)

    # --- Scenario 2: Multi-regime (2 years) ---
    print("\n\n" + "#"*60)
    print("  SCENARIO 2: Multi-Regime (2 Years, Bull→Crash→Recovery)")
    print("#"*60)

    prices_2y, returns_2y = generate_multi_regime_prices(n_days=730, start_price=3000, seed=42)
    vol_2y = ewma_vol(returns_2y)

    print(f"\n  Price range: ${prices_2y.min():.0f} — ${prices_2y.max():.0f}")
    print(f"  Start: ${prices_2y[0]:.0f} → End: ${prices_2y[-1]:.0f} ({(prices_2y[-1]/prices_2y[0]-1)*100:+.1f}%)")
    print(f"  Realized vol: {np.std(returns_2y[1:]) * np.sqrt(365.25):.1%}")

    results_2y = [
        backtest_covered_call(prices_2y, 7, 0.25, CAPITAL, vol_2y),
        backtest_cash_secured_put(prices_2y, 7, 0.25, CAPITAL, vol_2y),
        backtest_iron_condor(prices_2y, 7, 0.20, 0.05, CAPITAL, vol_2y),
        backtest_bull_call_spread(prices_2y, 14, 0.55, 0.25, CAPITAL, vol_2y),
        backtest_straddle(prices_2y, 7, CAPITAL, vol_2y),
    ]

    for r in results_2y:
        print_result(r)
    print_comparison_table(results_2y)

    # AutoVault multi-regime
    print("\n\n" + "#"*60)
    print("  AUTO VAULT — MULTI-REGIME (2 Years)")
    print("#"*60)

    auto_2y = []
    for tier in ["conservative", "moderate", "aggressive"]:
        r = backtest_auto_vault(prices_2y, 7, CAPITAL, vol_2y, tier)
        auto_2y.append(r)
    print_comparison_table(auto_2y)

    # --- Fee Analysis ---
    print_fee_analysis(results_1y + auto_results[:1])  # 1Y individual + conservative auto

    # --- Scenario 3: Stress Test (high vol crash) ---
    print("\n\n" + "#"*60)
    print("  SCENARIO 3: STRESS TEST — Flash Crash + Recovery")
    print("#"*60)

    prices_stress, returns_stress = generate_eth_prices(
        n_days=180, start_price=3000, annual_drift=-1.0,
        base_vol=1.20, jump_prob=0.05, jump_size=0.12, seed=99
    )
    vol_stress = ewma_vol(returns_stress)

    print(f"\n  Price range: ${prices_stress.min():.0f} — ${prices_stress.max():.0f}")
    print(f"  Start: ${prices_stress[0]:.0f} → End: ${prices_stress[-1]:.0f} ({(prices_stress[-1]/prices_stress[0]-1)*100:+.1f}%)")
    print(f"  Realized vol: {np.std(returns_stress[1:]) * np.sqrt(365.25):.1%}")

    stress_results = [
        backtest_covered_call(prices_stress, 7, 0.25, CAPITAL, vol_stress),
        backtest_cash_secured_put(prices_stress, 7, 0.25, CAPITAL, vol_stress),
        backtest_iron_condor(prices_stress, 7, 0.20, 0.05, CAPITAL, vol_stress),
        backtest_straddle(prices_stress, 7, CAPITAL, vol_stress),
        backtest_auto_vault(prices_stress, 7, CAPITAL, vol_stress, "conservative"),
        backtest_auto_vault(prices_stress, 7, CAPITAL, vol_stress, "aggressive"),
    ]
    print_comparison_table(stress_results)

    # --- Summary ---
    print("\n\n" + "="*60)
    print("  BACKTEST COMPLETE")
    print("="*60)
    print(f"  Scenarios run: 3 (Neutral 1Y, Multi-regime 2Y, Stress 6M)")
    print(f"  Strategies tested: 5 individual + 3 AutoVault tiers")
    print(f"  Total epochs simulated: {sum(len(r.epochs) for r in results_1y + results_2y + stress_results)}")
    print()


if __name__ == "__main__":
    main()
