// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title PricingEngine
/// @notice On-chain BSM pricing + EWMA vol + Greeks computation
/// @dev Ported from Python NomadPricingEngine prototype.
///      Used for: strike selection, premium validation, risk assessment
contract PricingEngine is Ownable {
    // --- Constants ---
    uint256 constant DECIMALS = 1e18;
    uint256 constant SECONDS_PER_YEAR = 365.25 days;

    // Risk tier target deltas (scaled by 100, e.g. 15 = 0.15)
    uint256 public constant CONSERVATIVE_DELTA = 15;
    uint256 public constant MODERATE_DELTA = 25;
    uint256 public constant AGGRESSIVE_DELTA = 35;

    // --- EWMA Volatility ---
    struct VolWindow {
        uint256 vol;            // EWMA vol (18 decimals)
        uint256 lastUpdate;
        uint256 lambda;         // Decay factor (18 decimals, e.g. 0.94)
    }

    // asset => window label => VolWindow
    mapping(address => mapping(bytes32 => VolWindow)) public volData;

    // Window labels
    bytes32 constant W_1H = keccak256("1h");
    bytes32 constant W_4H = keccak256("4h");
    bytes32 constant W_1D = keccak256("1d");
    bytes32 constant W_7D = keccak256("7d");
    bytes32 constant W_30D = keccak256("30d");

    event VolUpdated(address indexed asset, bytes32 window, uint256 newVol);
    event StrikeSelected(address indexed asset, uint256 strike, uint256 delta, uint256 riskTier);

    constructor(address owner_) Ownable(owner_) {}

    // --- BSM Pricing ---

    /// @notice Calculate BSM call price
    /// @param spot Current spot price (18 dec)
    /// @param strike Strike price (18 dec)
    /// @param vol Implied volatility (18 dec, e.g. 0.9e18 = 90%)
    /// @param timeToExpiry Time to expiry in seconds
    /// @param riskFreeRate Annual risk-free rate (18 dec)
    /// @return price Call option price (18 dec)
    function bsmCallPrice(
        uint256 spot,
        uint256 strike,
        uint256 vol,
        uint256 timeToExpiry,
        uint256 riskFreeRate
    ) external pure returns (uint256 price) {
        // TODO: Implement BSM formula
        // d1 = (ln(S/K) + (r + σ²/2) * T) / (σ * √T)
        // d2 = d1 - σ * √T
        // C = S * N(d1) - K * e^(-rT) * N(d2)
        // Requires: ln, exp, sqrt, normalCDF approximations
        return 0;
    }

    /// @notice Calculate BSM put price
    function bsmPutPrice(
        uint256 spot,
        uint256 strike,
        uint256 vol,
        uint256 timeToExpiry,
        uint256 riskFreeRate
    ) external pure returns (uint256 price) {
        // TODO: Put-call parity: P = C - S + K * e^(-rT)
        return 0;
    }

    // --- Greeks ---

    /// @notice Calculate option delta
    /// @return delta Delta value (18 dec, signed: negative for puts)
    function calcDelta(
        uint256 spot,
        uint256 strike,
        uint256 vol,
        uint256 timeToExpiry,
        bool isCall
    ) external pure returns (int256 delta) {
        // TODO: delta_call = N(d1), delta_put = N(d1) - 1
        return 0;
    }

    /// @notice Calculate option gamma
    function calcGamma(
        uint256 spot,
        uint256 strike,
        uint256 vol,
        uint256 timeToExpiry
    ) external pure returns (uint256 gamma) {
        // TODO: gamma = n(d1) / (S * σ * √T)
        return 0;
    }

    /// @notice Calculate option theta (daily decay)
    function calcTheta(
        uint256 spot,
        uint256 strike,
        uint256 vol,
        uint256 timeToExpiry,
        bool isCall
    ) external pure returns (int256 theta) {
        // TODO: theta = -(S * n(d1) * σ) / (2 * √T) - r * K * e^(-rT) * N(±d2)
        return 0;
    }

    /// @notice Calculate option vega
    function calcVega(
        uint256 spot,
        uint256 strike,
        uint256 vol,
        uint256 timeToExpiry
    ) external pure returns (uint256 vega) {
        // TODO: vega = S * n(d1) * √T
        return 0;
    }

    // --- Strike Selection ---

    /// @notice Find optimal strike for a given target delta
    /// @param spot Current spot price
    /// @param vol Implied volatility
    /// @param timeToExpiry Time to expiry
    /// @param targetDeltaBps Target delta in bps (e.g. 2500 = 0.25)
    /// @param isCall True for call, false for put
    /// @return strike Optimal strike price
    function findStrikeByDelta(
        uint256 spot,
        uint256 vol,
        uint256 timeToExpiry,
        uint256 targetDeltaBps,
        bool isCall
    ) external pure returns (uint256 strike) {
        // TODO: Binary search for strike that produces target delta
        return spot; // placeholder
    }

    // --- EWMA Vol Updates ---

    /// @notice Update EWMA volatility for an asset
    function updateVol(address asset, bytes32 window, uint256 returnSq) external onlyOwner {
        VolWindow storage vw = volData[asset][window];
        // EWMA: σ²_t = λ * σ²_{t-1} + (1-λ) * r²_t
        uint256 newVar = (vw.lambda * vw.vol * vw.vol / DECIMALS + (DECIMALS - vw.lambda) * returnSq / DECIMALS);
        // vol = sqrt(var) — placeholder, need sqrt implementation
        vw.vol = newVar; // TODO: take sqrt
        vw.lastUpdate = block.timestamp;
        emit VolUpdated(asset, window, vw.vol);
    }

    /// @notice Get blended vol across multiple windows
    function getBlendedVol(address asset) external view returns (uint256) {
        // Weight: 40% 1d + 30% 7d + 20% 4h + 10% 30d
        uint256 v1d = volData[asset][W_1D].vol;
        uint256 v7d = volData[asset][W_7D].vol;
        uint256 v4h = volData[asset][W_4H].vol;
        uint256 v30d = volData[asset][W_30D].vol;
        return (v1d * 40 + v7d * 30 + v4h * 20 + v30d * 10) / 100;
    }
}
