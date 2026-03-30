"""
Market Regime Detection Module
==============================
Classifies each week into one of 4 regimes using only backward-looking data.
No lookahead bias — only uses data available at the decision point.

Regimes:
  BULL_TREND       — SMA4 > SMA12, price > SMA4, trend strength high
  BEAR_TREND       — SMA4 < SMA12, price < SMA4, trend strength high
  HIGH_VOL_SIDEWAYS — no clear trend, realized vol > 60%
  LOW_VOL_SIDEWAYS  — no clear trend, realized vol <= 60%
"""

import numpy as np
from enum import Enum


class Regime(Enum):
    BULL_TREND = "BULL_TREND"
    BEAR_TREND = "BEAR_TREND"
    HIGH_VOL_SIDEWAYS = "HIGH_VOL_SIDEWAYS"
    LOW_VOL_SIDEWAYS = "LOW_VOL_SIDEWAYS"


# Regime → strategy weights: CC, CSP, IC, BCS, STR (rest = cash)
REGIME_WEIGHTS = {
    Regime.BULL_TREND:        {"CC": 0.05, "CSP": 0.15, "IC": 0.05, "BCS": 0.60, "STR": 0.00},
    Regime.BEAR_TREND:        {"CC": 0.00, "CSP": 0.05, "IC": 0.05, "BCS": 0.00, "STR": 0.00},
    Regime.HIGH_VOL_SIDEWAYS: {"CC": 0.25, "CSP": 0.25, "IC": 0.30, "BCS": 0.05, "STR": 0.05},
    Regime.LOW_VOL_SIDEWAYS:  {"CC": 0.30, "CSP": 0.20, "IC": 0.30, "BCS": 0.10, "STR": 0.00},
}


def sma(prices: np.ndarray, window: int) -> float:
    """Simple moving average of the last `window` prices."""
    if len(prices) < window:
        return np.mean(prices)
    return np.mean(prices[-window:])


def trend_strength(returns: np.ndarray, window: int = 4) -> float:
    """
    Simplified ADX-like trend strength indicator.
    Ratio of absolute cumulative return to sum of absolute returns.
    1.0 = perfect trend, 0.0 = pure noise.
    """
    if len(returns) < 2:
        return 0.0
    r = returns[-window:] if len(returns) >= window else returns
    cum = abs(np.sum(r))
    total = np.sum(np.abs(r))
    if total == 0:
        return 0.0
    return cum / total


def realized_vol_annualized(returns: np.ndarray, window: int = 4) -> float:
    """Trailing realized vol, annualized from weekly returns."""
    r = returns[-window:] if len(returns) >= window else returns
    if len(r) < 2:
        return 0.5
    return float(np.std(r) * np.sqrt(52))


def classify_regime(prices: np.ndarray, week_idx: int) -> Regime:
    """
    Classify market regime at `week_idx` using only data up to that point.
    No lookahead.

    Args:
        prices: full weekly close price array
        week_idx: current week index (0-based)

    Returns:
        Regime enum value
    """
    # Need at least a few weeks of history
    available = prices[:week_idx + 1]
    if len(available) < 4:
        return Regime.LOW_VOL_SIDEWAYS  # not enough data, be conservative

    # Compute weekly log returns
    returns = np.log(available[1:] / available[:-1])

    # SMAs
    current_price = available[-1]
    sma4 = sma(available, 4)
    sma12 = sma(available, 12)

    # Trend strength (ADX proxy)
    ts = trend_strength(returns, window=4)
    TREND_THRESHOLD = 0.40  # above this = trending

    # Realized vol
    rv = realized_vol_annualized(returns, window=4)
    HIGH_VOL_THRESHOLD = 0.60  # 60% annualized

    # Classification logic
    is_trending = ts > TREND_THRESHOLD

    if is_trending and sma4 > sma12 and current_price > sma4:
        return Regime.BULL_TREND
    elif is_trending and sma4 < sma12 and current_price < sma4:
        return Regime.BEAR_TREND
    elif rv > HIGH_VOL_THRESHOLD:
        return Regime.HIGH_VOL_SIDEWAYS
    else:
        return Regime.LOW_VOL_SIDEWAYS


def get_regime_weights(regime: Regime) -> dict:
    """Get strategy allocation weights for a given regime."""
    return REGIME_WEIGHTS[regime]


def get_cash_weight(regime: Regime) -> float:
    """Get the cash (idle) allocation for a regime."""
    weights = REGIME_WEIGHTS[regime]
    return 1.0 - sum(weights.values())


def classify_all_weeks(prices: np.ndarray) -> list[Regime]:
    """Classify regime for every week in the price series."""
    return [classify_regime(prices, i) for i in range(len(prices))]


def print_regime_summary(prices: np.ndarray, dates: list[str]):
    """Print regime classification for all weeks."""
    regimes = classify_all_weeks(prices)
    counts = {}
    for r in regimes:
        counts[r.value] = counts.get(r.value, 0) + 1

    print(f"\n  레짐 분류 요약 ({len(regimes)}주):")
    for regime, count in sorted(counts.items()):
        pct = count / len(regimes) * 100
        print(f"    {regime:<25} {count:>3}주 ({pct:.0f}%)")

    print(f"\n  {'주':>3} {'날짜':>12} {'ETH':>8} {'레짐':<25} {'SMA4':>8} {'SMA12':>8} {'Cash%':>6}")
    print(f"  {'-'*80}")
    for i in range(len(regimes)):
        if i >= len(dates):
            break
        avail = prices[:i + 1]
        s4 = sma(avail, 4)
        s12 = sma(avail, 12)
        cash = get_cash_weight(regimes[i]) * 100
        print(f"  {i:>3} {dates[i]:>12} {prices[i]:>8,.0f} {regimes[i].value:<25} {s4:>8,.0f} {s12:>8,.0f} {cash:>5.0f}%")
