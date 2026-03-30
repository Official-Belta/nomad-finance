// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHyperCore
/// @notice Interface for HyperCore perpetual DEX interactions
interface IHyperCore {
    struct Order {
        address asset;
        uint256 size;
        uint256 price;
        bool isLong;
        uint256 leverage;
    }

    /// @notice Open a perpetual position
    function openPosition(Order calldata order) external returns (bytes32 positionId);

    /// @notice Close a perpetual position
    function closePosition(bytes32 positionId) external returns (int256 pnl);

    /// @notice Modify an existing position
    function modifyPosition(bytes32 positionId, uint256 newSize, uint256 newLeverage) external;

    /// @notice Get position details
    function getPosition(bytes32 positionId)
        external
        view
        returns (address asset, uint256 size, uint256 entryPrice, bool isLong, int256 unrealizedPnl);

    /// @notice Get the mark price for an asset
    function getMarkPrice(address asset) external view returns (uint256);

    /// @notice Get available liquidity for an asset
    function getAvailableLiquidity(address asset) external view returns (uint256);
}
