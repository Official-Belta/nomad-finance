// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPricing
/// @notice Interface for on-chain asset pricing
interface IPricing {
    /// @notice Get the price of an asset in USD (18 decimals)
    function getPrice(address asset) external view returns (uint256 price);

    /// @notice Get the price with a max acceptable staleness
    function getPriceWithStaleness(address asset, uint256 maxAge) external view returns (uint256 price);

    /// @notice Check if pricing data is available for an asset
    function isSupported(address asset) external view returns (bool);
}
