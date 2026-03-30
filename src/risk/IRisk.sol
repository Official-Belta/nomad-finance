// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRisk
/// @notice Interface for risk assessment and limits
interface IRisk {
    /// @notice Check if a proposed position is within risk limits
    function checkRisk(uint256 positionSize, uint256 totalExposure) external view returns (bool allowed);

    /// @notice Get the maximum allowed exposure
    function maxExposure() external view returns (uint256);

    /// @notice Get the current portfolio risk score (basis points, higher = riskier)
    function riskScore() external view returns (uint256);

    /// @notice Get the maximum allowed drawdown in basis points
    function maxDrawdown() external view returns (uint256);
}
