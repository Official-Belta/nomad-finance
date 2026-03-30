"""
Black-Scholes-Merton pricing engine for backtesting.
Mirrors the on-chain PricingEngine.sol logic.
"""

import numpy as np
from scipy.stats import norm


def bsm_call(S: float, K: float, T: float, sigma: float, r: float = 0.0) -> float:
    """BSM European call price."""
    if T <= 0 or sigma <= 0:
        return max(S - K, 0)
    d1 = (np.log(S / K) + (r + sigma**2 / 2) * T) / (sigma * np.sqrt(T))
    d2 = d1 - sigma * np.sqrt(T)
    return S * norm.cdf(d1) - K * np.exp(-r * T) * norm.cdf(d2)


def bsm_put(S: float, K: float, T: float, sigma: float, r: float = 0.0) -> float:
    """BSM European put price."""
    if T <= 0 or sigma <= 0:
        return max(K - S, 0)
    d1 = (np.log(S / K) + (r + sigma**2 / 2) * T) / (sigma * np.sqrt(T))
    d2 = d1 - sigma * np.sqrt(T)
    return K * np.exp(-r * T) * norm.cdf(-d2) - S * norm.cdf(-d1)


def delta_call(S: float, K: float, T: float, sigma: float, r: float = 0.0) -> float:
    if T <= 0 or sigma <= 0:
        return 1.0 if S > K else 0.0
    d1 = (np.log(S / K) + (r + sigma**2 / 2) * T) / (sigma * np.sqrt(T))
    return norm.cdf(d1)


def delta_put(S: float, K: float, T: float, sigma: float, r: float = 0.0) -> float:
    return delta_call(S, K, T, sigma, r) - 1.0


def gamma(S: float, K: float, T: float, sigma: float, r: float = 0.0) -> float:
    if T <= 0 or sigma <= 0:
        return 0.0
    d1 = (np.log(S / K) + (r + sigma**2 / 2) * T) / (sigma * np.sqrt(T))
    return norm.pdf(d1) / (S * sigma * np.sqrt(T))


def vega(S: float, K: float, T: float, sigma: float, r: float = 0.0) -> float:
    if T <= 0 or sigma <= 0:
        return 0.0
    d1 = (np.log(S / K) + (r + sigma**2 / 2) * T) / (sigma * np.sqrt(T))
    return S * norm.pdf(d1) * np.sqrt(T) / 100  # per 1% vol move


def theta_call(S: float, K: float, T: float, sigma: float, r: float = 0.0) -> float:
    if T <= 0 or sigma <= 0:
        return 0.0
    d1 = (np.log(S / K) + (r + sigma**2 / 2) * T) / (sigma * np.sqrt(T))
    d2 = d1 - sigma * np.sqrt(T)
    term1 = -(S * norm.pdf(d1) * sigma) / (2 * np.sqrt(T))
    term2 = -r * K * np.exp(-r * T) * norm.cdf(d2)
    return (term1 + term2) / 365.25


def find_strike_by_delta(S: float, sigma: float, T: float, target_delta: float,
                         is_call: bool, r: float = 0.0) -> float:
    """Binary search for strike producing target delta."""
    if is_call:
        lo, hi = S, S * 3
    else:
        lo, hi = S / 3, S

    for _ in range(60):
        mid = (lo + hi) / 2
        d1 = (np.log(S / mid) + (r + sigma**2 / 2) * T) / (sigma * np.sqrt(T))
        if is_call:
            d = norm.cdf(d1)
            if d > target_delta:
                lo = mid
            else:
                hi = mid
        else:
            d = abs(norm.cdf(d1) - 1)
            if d > target_delta:
                hi = mid
            else:
                lo = mid

        if hi - lo < 0.01:
            break

    return (lo + hi) / 2


def ewma_vol(returns: np.ndarray, lam: float = 0.94) -> np.ndarray:
    """EWMA volatility estimation (annualized)."""
    var = np.zeros(len(returns))
    var[0] = returns[0] ** 2
    for i in range(1, len(returns)):
        var[i] = lam * var[i - 1] + (1 - lam) * returns[i] ** 2
    return np.sqrt(var) * np.sqrt(365.25)  # annualize daily vol
