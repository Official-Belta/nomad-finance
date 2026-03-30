// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICiao
/// @notice Interface for Rysk Ciao protocol — margin account & settlement
/// @dev Ciao handles collateral management, balance updates, and PnL settlement
interface ICiao {
    /// @notice Deposit collateral into a sub-account
    function deposit(uint256 subAccountId, uint256 amount) external;

    /// @notice Request withdrawal from a sub-account
    function requestWithdrawal(uint256 subAccountId, uint256 amount) external;

    /// @notice Settle core collateral (PnL settlement)
    function settleCoreCollateral(uint256 subAccountId) external;

    /// @notice Get sub-account balance
    function getBalance(address account, uint256 subAccountId) external view returns (uint256);

    /// @notice Get sub-account margin health
    function getMarginHealth(address account, uint256 subAccountId)
        external
        view
        returns (uint256 marginUsed, uint256 marginAvailable, bool isHealthy);
}
