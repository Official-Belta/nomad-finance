// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStrategy
/// @notice Interface for pluggable vault yield strategies
/// @dev All strategies sell options via Rysk RFQ and collect premium
interface IStrategy {
    /// @notice Deploy USDC into the strategy as collateral
    function deposit(uint256 amount) external;

    /// @notice Withdraw USDC from the strategy
    function withdraw(uint256 amount) external returns (uint256 actualWithdrawn);

    /// @notice Harvest yield — settle expired options, collect premium
    function harvest() external returns (uint256 profit);

    /// @notice Total USDC currently deployed in this strategy
    function totalDeployedAssets() external view returns (uint256);

    /// @notice Estimated APR in basis points (100 = 1%)
    function estimatedAPR() external view returns (uint256);

    /// @notice Get the strategy's current net delta exposure
    function netDelta() external view returns (int256);

    /// @notice Emergency close all positions
    function emergencyClose() external;
}
