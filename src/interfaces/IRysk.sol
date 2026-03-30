// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRysk
/// @notice Interface for Rysk options protocol interactions
interface IRysk {
    struct OptionParams {
        address underlying;
        uint256 strikePrice;
        uint256 expiry;
        bool isCall;
        uint256 amount;
    }

    /// @notice Buy options
    function buyOption(OptionParams calldata params) external returns (bytes32 optionId, uint256 premium);

    /// @notice Sell/write options
    function sellOption(OptionParams calldata params) external returns (bytes32 optionId, uint256 premium);

    /// @notice Exercise an option
    function exercise(bytes32 optionId) external returns (uint256 payout);

    /// @notice Get the current implied volatility for an asset
    function getImpliedVolatility(address underlying, uint256 strikePrice, uint256 expiry, bool isCall)
        external
        view
        returns (uint256);

    /// @notice Get option Greeks
    function getGreeks(bytes32 optionId)
        external
        view
        returns (int256 delta, int256 gamma, int256 theta, int256 vega);

    /// @notice Get premium quote for an option
    function quotePremium(OptionParams calldata params) external view returns (uint256 premium);
}
