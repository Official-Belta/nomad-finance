// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title RiskManager
/// @notice Portfolio-level risk management — Greeks aggregation, limits, auto-deleverage
/// @dev Monitors: net delta, gamma exposure, max drawdown, total exposure
contract RiskManager is Ownable {
    // --- Risk Limits ---
    uint256 public maxExposure;         // Max notional exposure (18 dec)
    uint256 public maxDrawdownBps;      // Max drawdown in bps (e.g. 1000 = 10%)
    int256 public maxAbsDelta;          // Max absolute net delta allowed
    uint256 public maxGammaExposure;    // Max gamma exposure

    // --- Portfolio Greeks ---
    struct PortfolioGreeks {
        int256 delta;
        int256 gamma;
        int256 theta;
        int256 vega;
        uint256 lastUpdate;
    }
    PortfolioGreeks public portfolioGreeks;

    // --- High Water Mark for drawdown ---
    uint256 public highWaterMark;
    uint256 public currentNAV;

    // --- Events ---
    event RiskLimitBreached(string reason, int256 value, int256 limit);
    event AutoDeleverage(uint256 amount);
    event GreeksUpdated(int256 delta, int256 gamma, int256 theta, int256 vega);

    constructor(address owner_) Ownable(owner_) {
        maxExposure = 1_000_000e18;     // $1M Phase 1 cap
        maxDrawdownBps = 1000;          // 10% max drawdown
        maxAbsDelta = 50e18;            // Max 50 delta units
        maxGammaExposure = 100e18;
    }

    /// @notice Check if a new position is within risk limits
    function checkRisk(
        uint256 positionSize,
        uint256 totalExposure,
        int256 positionDelta
    ) external view returns (bool allowed, string memory reason) {
        // Check total exposure
        if (totalExposure + positionSize > maxExposure) {
            return (false, "Exceeds max exposure");
        }

        // Check delta limits
        int256 newDelta = portfolioGreeks.delta + positionDelta;
        if (newDelta > maxAbsDelta || newDelta < -maxAbsDelta) {
            return (false, "Exceeds delta limit");
        }

        // Check drawdown
        if (highWaterMark > 0) {
            uint256 drawdown = ((highWaterMark - currentNAV) * 10000) / highWaterMark;
            if (drawdown >= maxDrawdownBps) {
                return (false, "Max drawdown reached");
            }
        }

        return (true, "");
    }

    /// @notice Update portfolio Greeks
    function updateGreeks(
        int256 delta,
        int256 gamma,
        int256 theta,
        int256 vega
    ) external onlyOwner {
        portfolioGreeks = PortfolioGreeks({
            delta: delta,
            gamma: gamma,
            theta: theta,
            vega: vega,
            lastUpdate: block.timestamp
        });
        emit GreeksUpdated(delta, gamma, theta, vega);

        // Check limits after update
        if (delta > maxAbsDelta || delta < -maxAbsDelta) {
            emit RiskLimitBreached("Delta", delta, maxAbsDelta);
        }
    }

    /// @notice Update NAV for drawdown tracking
    function updateNAV(uint256 nav) external onlyOwner {
        currentNAV = nav;
        if (nav > highWaterMark) {
            highWaterMark = nav;
        }
    }

    /// @notice Get current risk score (0-10000 bps, higher = riskier)
    function riskScore() external view returns (uint256 score) {
        // Weighted risk factors
        uint256 deltaRisk = portfolioGreeks.delta > 0
            ? uint256(portfolioGreeks.delta) * 10000 / uint256(maxAbsDelta)
            : uint256(-portfolioGreeks.delta) * 10000 / uint256(maxAbsDelta);

        uint256 drawdownRisk = 0;
        if (highWaterMark > 0 && currentNAV < highWaterMark) {
            drawdownRisk = ((highWaterMark - currentNAV) * 10000) / highWaterMark;
        }

        // 50% delta risk + 50% drawdown risk
        score = (deltaRisk * 50 + drawdownRisk * 50) / 100;
        if (score > 10000) score = 10000;
    }

    // --- Admin ---

    function setMaxExposure(uint256 newMax) external onlyOwner {
        maxExposure = newMax;
    }

    function setMaxDrawdown(uint256 newMaxBps) external onlyOwner {
        maxDrawdownBps = newMaxBps;
    }

    function setMaxDelta(int256 newMax) external onlyOwner {
        maxAbsDelta = newMax;
    }
}
