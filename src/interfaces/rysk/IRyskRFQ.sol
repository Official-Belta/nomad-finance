// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRyskRFQ
/// @notice Interface for Rysk V12 RFQ option trading
/// @dev Off-chain: WebSocket RFQ matching. On-chain: Ciao settlement.
///      Rysk RFQ is used for all option sells (premium collection).
interface IRyskRFQ {
    struct OptionQuote {
        address assetAddress;       // Underlying asset
        uint256 strike;             // Strike price (18 decimals)
        uint256 expiry;             // Expiration timestamp
        bool isPut;                 // true = put, false = call
        bool isTakerBuy;            // true = taker buys (we sell)
        uint256 price;              // Premium per contract (18 decimals)
        uint256 quantity;           // Number of contracts
        address collateralAsset;    // Collateral token (USDC)
        uint256 validUntil;         // Quote validity timestamp
        uint256 nonce;              // Replay protection
    }

    /// @notice Submit a signed option quote to Rysk RFQ
    function submitQuote(OptionQuote calldata quote, bytes calldata signature) external returns (bytes32 quoteId);

    /// @notice Cancel an active quote
    function cancelQuote(bytes32 quoteId) external;

    /// @notice Get quote status
    function getQuoteStatus(bytes32 quoteId) external view returns (uint8 status);
}
