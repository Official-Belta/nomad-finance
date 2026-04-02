"""
Hyperliquid ETH Perpetual Funding Rate Data
============================================
Calibrated from known crypto funding rate characteristics:
- 8-hour funding intervals (3x per day)
- Positive when longs pay shorts (bull bias)
- Negative when shorts pay longs (bear bias)
- Typical range: -0.05% to +0.10% per 8h

Funding rates are strongly correlated with:
1. Market direction (bull = positive, bear = negative)
2. Speculative positioning (leverage = higher rates)
3. Spot-perp basis
4. Overall crypto sentiment

Data calibration sources:
- ETH perp funding averages 0.01% per 8h baseline
- Bull markets: 0.01-0.05% (can spike to 0.1%+ during euphoria)
- Bear markets: -0.01 to 0.005%
- Sideways: 0.005-0.015%
- Known: Aug 2025 ATH period had extreme positive funding
- Known: Feb 2026 crash had negative funding
"""

import numpy as np
from eth_weekly_prices import ETH_WEEKLY_CLOSE, WEEK_DATES, get_weekly_returns
from regime import classify_all_weeks, Regime


def generate_funding_rates(weekly_prices: np.ndarray) -> np.ndarray:
    """
    Generate realistic 8-hourly funding rates aligned with weekly price data.
    Each week has 21 funding intervals (3 per day × 7 days).
    Returns array of shape (n_weeks, 21) with 8h funding rates.

    Calibrated to real crypto market dynamics:
    - Strong positive correlation with weekly return direction
    - Mean-reverting around regime-dependent baseline
    - Fat tails (occasional spikes during euphoria/panic)
    - Autocorrelation (high funding tends to persist)
    """
    rng = np.random.default_rng(42)
    n_weeks = len(weekly_prices) - 1
    weekly_rets = get_weekly_returns(weekly_prices)
    regimes = classify_all_weeks(weekly_prices)

    # Regime baselines (8h rate)
    REGIME_BASE = {
        Regime.BULL_TREND: 0.00025,        # 0.025% per 8h ≈ 27% ann
        Regime.LOW_VOL_SIDEWAYS: 0.00010,  # 0.010% per 8h ≈ 11% ann
        Regime.HIGH_VOL_SIDEWAYS: 0.00015, # 0.015% per 8h ≈ 16% ann
        Regime.BEAR_TREND: -0.00005,       # -0.005% per 8h ≈ -5% ann
    }

    all_rates = np.zeros((n_weeks, 21))
    prev_rate = 0.0001  # start at baseline

    for w in range(n_weeks):
        regime = regimes[w] if w < len(regimes) else Regime.LOW_VOL_SIDEWAYS
        base = REGIME_BASE[regime]
        week_ret = weekly_rets[w] if w < len(weekly_rets) else 0

        # Funding rate influenced by: base + return signal + noise + persistence
        for i in range(21):
            # Mean reversion toward regime base
            mean_rev = 0.3 * (base - prev_rate)

            # Return signal: positive weekly return → higher funding
            ret_signal = week_ret * 0.002  # scale down

            # Noise
            noise = rng.normal(0, 0.00005)

            # Persistence
            new_rate = prev_rate + mean_rev + ret_signal / 21 + noise

            # Spike probability during extreme moves
            if abs(week_ret) > 0.10:  # >10% weekly move
                spike = rng.normal(0, 0.0003) * np.sign(week_ret)
                new_rate += spike

            # Clamp to realistic range [-0.05%, +0.15%]
            new_rate = np.clip(new_rate, -0.0005, 0.0015)

            all_rates[w, i] = new_rate
            prev_rate = new_rate

    return all_rates


def weekly_funding_summary(rates: np.ndarray) -> np.ndarray:
    """Sum of 21 funding intervals per week → weekly funding yield."""
    return np.sum(rates, axis=1)


def annualized_funding_yield(rates: np.ndarray) -> float:
    """Compute annualized funding yield from 8h rates."""
    weekly = weekly_funding_summary(rates)
    return float(np.mean(weekly) * 52)


def print_funding_summary(rates: np.ndarray, dates: list[str]):
    """Print funding rate summary by week."""
    weekly = weekly_funding_summary(rates)
    ann = annualized_funding_yield(rates)

    print(f"\n  펀딩비 요약:")
    print(f"  연환산 평균 수익률: {ann*100:.1f}%")
    print(f"  주간 펀딩 범위: {weekly.min()*100:.3f}% ~ {weekly.max()*100:.3f}%")
    print(f"  양수 주: {np.sum(weekly > 0)}/{len(weekly)} ({np.mean(weekly > 0)*100:.0f}%)")

    print(f"\n  {'주':>3} {'날짜':>12} {'주간펀딩':>10} {'8h평균':>10} {'연환산':>10}")
    print(f"  {'-'*55}")
    for w in range(len(weekly)):
        if w >= len(dates):
            break
        avg_8h = np.mean(rates[w])
        ann_rate = avg_8h * 3 * 365
        print(f"  {w:>3} {dates[w]:>12} {weekly[w]*100:>9.3f}% {avg_8h*100:>9.4f}% {ann_rate*100:>9.1f}%")
