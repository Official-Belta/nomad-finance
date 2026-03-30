// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStrategy
/// @notice Interface for vault yield strategies
interface IStrategy {
    /// @notice Deploy assets into the strategy
    function deposit(uint256 amount) external;

    /// @notice Withdraw assets from the strategy
    function withdraw(uint256 amount) external returns (uint256 actualWithdrawn);

    /// @notice Harvest yield and reinvest
    function harvest() external returns (uint256 profit);

    /// @notice Total assets currently deployed in this strategy
    function totalDeployedAssets() external view returns (uint256);

    /// @notice Estimated APY in basis points (1 = 0.01%)
    function estimatedAPY() external view returns (uint256);
}
