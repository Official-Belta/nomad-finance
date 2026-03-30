"""
Strategy simulators for backtesting.
Each strategy returns epoch-by-epoch PnL given price paths and vol.
"""

import numpy as np
from dataclasses import dataclass, field
from typing import List

from pricing import (
    bsm_call, bsm_put, delta_call, delta_put,
    find_strike_by_delta, gamma, vega
)


@dataclass
class EpochResult:
    epoch: int
    entry_price: float
    exit_price: float
    strike: float
    premium: float
    intrinsic_pnl: float     # Option settlement PnL (for seller: premium - max(payoff, 0))
    hedge_pnl: float         # Delta hedge PnL
    total_pnl: float         # Net PnL for the epoch
    vol_used: float


@dataclass
class BacktestResult:
    strategy_name: str
    epochs: List[EpochResult] = field(default_factory=list)
    initial_capital: float = 0
    final_capital: float = 0

    @property
    def total_return(self) -> float:
        if self.initial_capital == 0:
            return 0
        return (self.final_capital - self.initial_capital) / self.initial_capital

    @property
    def annualized_return(self) -> float:
        n_epochs = len(self.epochs)
        if n_epochs == 0:
            return 0
        epochs_per_year = 365.25 / 7  # 7-day epochs
        total_ret = self.total_return
        if total_ret <= -1:
            return -1
        return (1 + total_ret) ** (epochs_per_year / n_epochs) - 1

    @property
    def epoch_returns(self) -> np.ndarray:
        if not self.epochs:
            return np.array([])
        capital = self.initial_capital
        rets = []
        for e in self.epochs:
            r = e.total_pnl / capital if capital > 0 else 0
            rets.append(r)
            capital += e.total_pnl
        return np.array(rets)

    @property
    def sharpe_ratio(self) -> float:
        rets = self.epoch_returns
        if len(rets) < 2:
            return 0
        ann_factor = np.sqrt(365.25 / 7)
        return (np.mean(rets) / np.std(rets)) * ann_factor if np.std(rets) > 0 else 0

    @property
    def max_drawdown(self) -> float:
        rets = self.epoch_returns
        if len(rets) == 0:
            return 0
        cumulative = np.cumprod(1 + rets)
        peak = np.maximum.accumulate(cumulative)
        drawdown = (peak - cumulative) / peak
        return np.max(drawdown)

    @property
    def win_rate(self) -> float:
        if not self.epochs:
            return 0
        wins = sum(1 for e in self.epochs if e.total_pnl > 0)
        return wins / len(self.epochs)


def _delta_hedge_pnl(entry_price: float, exit_price: float, delta: float,
                     notional: float, n_rehedges: int = 3,
                     prices_path: np.ndarray = None) -> float:
    """
    Simulate delta hedging PnL.
    For a short option position, we hedge by holding `delta` units of underlying.
    Simplified: discrete rehedging with slippage.
    """
    if prices_path is None or len(prices_path) < 2:
        # Simple single-hedge approximation
        hedge_size = delta * notional / entry_price
        price_change = exit_price - entry_price
        return hedge_size * price_change

    # Multi-step hedge simulation
    total_pnl = 0.0
    hedge_pos = 0.0
    step = max(1, len(prices_path) // (n_rehedges + 1))

    for i in range(0, len(prices_path) - 1, step):
        S = prices_path[i]
        # Close old hedge
        if i > 0:
            price_diff = S - prices_path[max(0, i - step)]
            total_pnl += hedge_pos * price_diff

        # Rehedge: not modeled precisely here, just update position
        # (In reality would recalculate delta at current price)
        hedge_pos = delta * notional / S

    # Final settlement
    price_diff = prices_path[-1] - prices_path[-(step + 1) if len(prices_path) > step else 0]
    total_pnl += hedge_pos * price_diff

    # Slippage cost: ~0.05% per rehedge
    slippage = notional * 0.0005 * n_rehedges
    return total_pnl - slippage


# =============================================================================
#                          COVERED CALL
# =============================================================================

def backtest_covered_call(
    prices: np.ndarray,
    epoch_days: int = 7,
    target_delta: float = 0.25,
    capital: float = 1_000_000,
    vol_series: np.ndarray = None,
) -> BacktestResult:
    """Backtest covered call: sell OTM call each epoch, delta hedge."""
    result = BacktestResult(strategy_name="CoveredCall", initial_capital=capital)
    nav = capital
    n_epochs = len(prices) // epoch_days

    for ep in range(n_epochs):
        start_idx = ep * epoch_days
        end_idx = start_idx + epoch_days
        if end_idx >= len(prices):
            break

        S = prices[start_idx]
        S_end = prices[end_idx]
        T = epoch_days / 365.25
        sigma = vol_series[start_idx] if vol_series is not None else 0.80

        # Find OTM call strike
        strike = find_strike_by_delta(S, sigma, T, target_delta, is_call=True)
        premium = bsm_call(S, strike, T, sigma)
        d = delta_call(S, strike, T, sigma)

        # Option settlement: short call payoff
        call_payoff = max(S_end - strike, 0)
        option_pnl = premium - call_payoff  # premium received - payoff owed

        # Delta hedge PnL (hedge the short call delta)
        epoch_prices = prices[start_idx:end_idx + 1]
        hedge_pnl = _delta_hedge_pnl(S, S_end, -d, nav, n_rehedges=3, prices_path=epoch_prices)

        # Scale by capital utilization
        notional_ratio = nav / S if S > 0 else 0
        total_pnl = (option_pnl * notional_ratio) + hedge_pnl

        epoch_result = EpochResult(
            epoch=ep, entry_price=S, exit_price=S_end,
            strike=strike, premium=premium * notional_ratio,
            intrinsic_pnl=option_pnl * notional_ratio,
            hedge_pnl=hedge_pnl, total_pnl=total_pnl, vol_used=sigma,
        )
        result.epochs.append(epoch_result)
        nav += total_pnl

    result.final_capital = nav
    return result


# =============================================================================
#                        CASH-SECURED PUT
# =============================================================================

def backtest_cash_secured_put(
    prices: np.ndarray,
    epoch_days: int = 7,
    target_delta: float = 0.25,
    capital: float = 1_000_000,
    vol_series: np.ndarray = None,
) -> BacktestResult:
    """Backtest cash-secured put: sell OTM put each epoch."""
    result = BacktestResult(strategy_name="CashSecuredPut", initial_capital=capital)
    nav = capital
    n_epochs = len(prices) // epoch_days

    for ep in range(n_epochs):
        start_idx = ep * epoch_days
        end_idx = start_idx + epoch_days
        if end_idx >= len(prices):
            break

        S = prices[start_idx]
        S_end = prices[end_idx]
        T = epoch_days / 365.25
        sigma = vol_series[start_idx] if vol_series is not None else 0.80

        strike = find_strike_by_delta(S, sigma, T, target_delta, is_call=False)
        premium = bsm_put(S, strike, T, sigma)
        d = delta_put(S, strike, T, sigma)

        put_payoff = max(strike - S_end, 0)
        option_pnl = premium - put_payoff

        epoch_prices = prices[start_idx:end_idx + 1]
        hedge_pnl = _delta_hedge_pnl(S, S_end, -d, nav, n_rehedges=3, prices_path=epoch_prices)

        notional_ratio = nav / S if S > 0 else 0
        total_pnl = (option_pnl * notional_ratio) + hedge_pnl

        epoch_result = EpochResult(
            epoch=ep, entry_price=S, exit_price=S_end,
            strike=strike, premium=premium * notional_ratio,
            intrinsic_pnl=option_pnl * notional_ratio,
            hedge_pnl=hedge_pnl, total_pnl=total_pnl, vol_used=sigma,
        )
        result.epochs.append(epoch_result)
        nav += total_pnl

    result.final_capital = nav
    return result


# =============================================================================
#                          IRON CONDOR
# =============================================================================

def backtest_iron_condor(
    prices: np.ndarray,
    epoch_days: int = 7,
    short_delta: float = 0.20,
    spread_width_pct: float = 0.05,
    capital: float = 1_000_000,
    vol_series: np.ndarray = None,
) -> BacktestResult:
    """Backtest iron condor: sell OTM call + put, buy wings."""
    result = BacktestResult(strategy_name="IronCondor", initial_capital=capital)
    nav = capital
    n_epochs = len(prices) // epoch_days

    for ep in range(n_epochs):
        start_idx = ep * epoch_days
        end_idx = start_idx + epoch_days
        if end_idx >= len(prices):
            break

        S = prices[start_idx]
        S_end = prices[end_idx]
        T = epoch_days / 365.25
        sigma = vol_series[start_idx] if vol_series is not None else 0.80

        # Short strikes
        short_call_K = find_strike_by_delta(S, sigma, T, short_delta, is_call=True)
        short_put_K = find_strike_by_delta(S, sigma, T, short_delta, is_call=False)

        # Long strikes (wings)
        spread = S * spread_width_pct
        long_call_K = short_call_K + spread
        long_put_K = max(short_put_K - spread, 1)

        # Net premium = short premiums - long premiums
        short_call_prem = bsm_call(S, short_call_K, T, sigma)
        long_call_prem = bsm_call(S, long_call_K, T, sigma)
        short_put_prem = bsm_put(S, short_put_K, T, sigma)
        long_put_prem = bsm_put(S, long_put_K, T, sigma)
        net_premium = (short_call_prem + short_put_prem) - (long_call_prem + long_put_prem)

        # Settlement payoffs
        short_call_payoff = max(S_end - short_call_K, 0)
        long_call_payoff = max(S_end - long_call_K, 0)
        short_put_payoff = max(short_put_K - S_end, 0)
        long_put_payoff = max(long_put_K - S_end, 0)

        option_pnl = net_premium - (short_call_payoff - long_call_payoff) - (short_put_payoff - long_put_payoff)

        # Net delta is small for IC, minimal hedge needed
        cd = delta_call(S, short_call_K, T, sigma)
        pd = delta_put(S, short_put_K, T, sigma)
        net_d = -(cd + pd)  # short both

        epoch_prices = prices[start_idx:end_idx + 1]
        hedge_pnl = _delta_hedge_pnl(S, S_end, net_d, nav * 0.5, n_rehedges=2, prices_path=epoch_prices)

        notional_ratio = nav / S if S > 0 else 0
        total_pnl = (option_pnl * notional_ratio * 0.5) + hedge_pnl

        epoch_result = EpochResult(
            epoch=ep, entry_price=S, exit_price=S_end,
            strike=short_call_K, premium=net_premium * notional_ratio * 0.5,
            intrinsic_pnl=option_pnl * notional_ratio * 0.5,
            hedge_pnl=hedge_pnl, total_pnl=total_pnl, vol_used=sigma,
        )
        result.epochs.append(epoch_result)
        nav += total_pnl

    result.final_capital = nav
    return result


# =============================================================================
#                       BULL CALL SPREAD
# =============================================================================

def backtest_bull_call_spread(
    prices: np.ndarray,
    epoch_days: int = 14,
    long_delta: float = 0.55,
    short_delta: float = 0.25,
    capital: float = 1_000_000,
    vol_series: np.ndarray = None,
) -> BacktestResult:
    """Backtest bull call spread: buy ATM call + sell OTM call."""
    result = BacktestResult(strategy_name="BullCallSpread", initial_capital=capital)
    nav = capital
    n_epochs = len(prices) // epoch_days

    for ep in range(n_epochs):
        start_idx = ep * epoch_days
        end_idx = start_idx + epoch_days
        if end_idx >= len(prices):
            break

        S = prices[start_idx]
        S_end = prices[end_idx]
        T = epoch_days / 365.25
        sigma = vol_series[start_idx] if vol_series is not None else 0.80

        long_K = find_strike_by_delta(S, sigma, T, long_delta, is_call=True)
        short_K = find_strike_by_delta(S, sigma, T, short_delta, is_call=True)

        if short_K <= long_K:
            short_K = long_K * 1.05

        long_prem = bsm_call(S, long_K, T, sigma)
        short_prem = bsm_call(S, short_K, T, sigma)
        net_debit = long_prem - short_prem

        # Settlement
        long_payoff = max(S_end - long_K, 0)
        short_payoff = max(S_end - short_K, 0)
        spread_payoff = long_payoff - short_payoff
        option_pnl = spread_payoff - net_debit

        # Risk-size: only risk the net debit (limited risk)
        risk_fraction = min(net_debit / S, 0.10)  # max 10% of capital
        notional = nav * risk_fraction / net_debit if net_debit > 0 else 0
        total_pnl = option_pnl * notional

        epoch_result = EpochResult(
            epoch=ep, entry_price=S, exit_price=S_end,
            strike=long_K, premium=-net_debit * notional,
            intrinsic_pnl=option_pnl * notional,
            hedge_pnl=0, total_pnl=total_pnl, vol_used=sigma,
        )
        result.epochs.append(epoch_result)
        nav += total_pnl

    result.final_capital = nav
    return result


# =============================================================================
#                         SHORT STRADDLE
# =============================================================================

def backtest_straddle(
    prices: np.ndarray,
    epoch_days: int = 7,
    capital: float = 1_000_000,
    vol_series: np.ndarray = None,
) -> BacktestResult:
    """Backtest short straddle: sell ATM call + ATM put, heavy hedging."""
    result = BacktestResult(strategy_name="Straddle", initial_capital=capital)
    nav = capital
    n_epochs = len(prices) // epoch_days

    for ep in range(n_epochs):
        start_idx = ep * epoch_days
        end_idx = start_idx + epoch_days
        if end_idx >= len(prices):
            break

        S = prices[start_idx]
        S_end = prices[end_idx]
        T = epoch_days / 365.25
        sigma = vol_series[start_idx] if vol_series is not None else 0.80

        strike = S  # ATM
        call_prem = bsm_call(S, strike, T, sigma)
        put_prem = bsm_put(S, strike, T, sigma)
        total_premium = call_prem + put_prem

        # Settlement
        call_payoff = max(S_end - strike, 0)
        put_payoff = max(strike - S_end, 0)
        option_pnl = total_premium - call_payoff - put_payoff

        # Net delta: ATM straddle ≈ 0, but gamma is high
        cd = delta_call(S, strike, T, sigma)
        pd = delta_put(S, strike, T, sigma)
        net_d = -(cd + pd)

        epoch_prices = prices[start_idx:end_idx + 1]
        # More frequent rehedging for straddle (high gamma)
        hedge_pnl = _delta_hedge_pnl(S, S_end, net_d, nav * 0.5, n_rehedges=5, prices_path=epoch_prices)

        notional_ratio = nav / S * 0.5 if S > 0 else 0  # half capital per leg
        total_pnl = (option_pnl * notional_ratio) + hedge_pnl

        epoch_result = EpochResult(
            epoch=ep, entry_price=S, exit_price=S_end,
            strike=strike, premium=total_premium * notional_ratio,
            intrinsic_pnl=option_pnl * notional_ratio,
            hedge_pnl=hedge_pnl, total_pnl=total_pnl, vol_used=sigma,
        )
        result.epochs.append(epoch_result)
        nav += total_pnl

    result.final_capital = nav
    return result


# =============================================================================
#                       AUTO VAULT (MULTI-STRATEGY)
# =============================================================================

def backtest_auto_vault(
    prices: np.ndarray,
    epoch_days: int = 7,
    capital: float = 1_000_000,
    vol_series: np.ndarray = None,
    risk_tier: str = "moderate",
) -> BacktestResult:
    """
    Backtest the NomadAutoVault multi-strategy allocation.
    Runs sub-strategies with weighted capital allocation.
    """
    # Risk tier weights
    TIERS = {
        "conservative": {"CC": 0.70, "CSP": 0.20, "IC": 0.10, "BCS": 0.0, "STR": 0.0},
        "moderate":     {"CC": 0.40, "CSP": 0.20, "IC": 0.25, "BCS": 0.10, "STR": 0.05},
        "aggressive":   {"CC": 0.30, "CSP": 0.10, "IC": 0.30, "BCS": 0.20, "STR": 0.10},
    }
    weights = TIERS[risk_tier]

    sub_results = {}
    if weights["CC"] > 0:
        sub_results["CC"] = backtest_covered_call(prices, epoch_days, 0.25, capital * weights["CC"], vol_series)
    if weights["CSP"] > 0:
        sub_results["CSP"] = backtest_cash_secured_put(prices, epoch_days, 0.25, capital * weights["CSP"], vol_series)
    if weights["IC"] > 0:
        sub_results["IC"] = backtest_iron_condor(prices, epoch_days, 0.20, 0.05, capital * weights["IC"], vol_series)
    if weights["BCS"] > 0:
        sub_results["BCS"] = backtest_bull_call_spread(prices, 14, 0.55, 0.25, capital * weights["BCS"], vol_series)
    if weights["STR"] > 0:
        sub_results["STR"] = backtest_straddle(prices, epoch_days, capital * weights["STR"], vol_series)

    # Aggregate into single result
    result = BacktestResult(
        strategy_name=f"AutoVault ({risk_tier})",
        initial_capital=capital,
    )

    # Combine epoch PnLs
    n_epochs = len(prices) // epoch_days
    nav = capital
    for ep in range(n_epochs):
        total_ep_pnl = 0
        for name, sr in sub_results.items():
            if ep < len(sr.epochs):
                total_ep_pnl += sr.epochs[ep].total_pnl

        S = prices[ep * epoch_days] if ep * epoch_days < len(prices) else 0
        S_end = prices[min((ep + 1) * epoch_days, len(prices) - 1)]

        result.epochs.append(EpochResult(
            epoch=ep, entry_price=S, exit_price=S_end,
            strike=0, premium=0,
            intrinsic_pnl=total_ep_pnl, hedge_pnl=0,
            total_pnl=total_ep_pnl, vol_used=0,
        ))
        nav += total_ep_pnl

    result.final_capital = nav
    return result
