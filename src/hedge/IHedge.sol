// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHedge
/// @notice Interface for hedging operations (perps, options)
interface IHedge {
    /// @notice Open a hedge position
    /// @param size Notional size of the hedge
    /// @param isShort True for short hedge, false for long
    function openHedge(uint256 size, bool isShort) external returns (bytes32 positionId);

    /// @notice Close an existing hedge position
    function closeHedge(bytes32 positionId) external returns (int256 pnl);

    /// @notice Adjust an existing hedge position
    function adjustHedge(bytes32 positionId, uint256 newSize) external;

    /// @notice Get the current net delta exposure
    function netDelta() external view returns (int256);

    /// @notice Get unrealized PnL of all hedge positions
    function unrealizedPnL() external view returns (int256);
}
