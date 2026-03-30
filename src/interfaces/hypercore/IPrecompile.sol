// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPrecompile
/// @notice Precompile addresses for reading HyperCore state from HyperEVM
/// @dev These are staticcall targets, not traditional contract interfaces.
///      Use PrecompileLib from hyper-evm-lib for high-level access.
///
/// Precompile addresses:
///   0x0800 — Position data
///   0x0801 — Balance queries
///   0x0802 — Vault equity
///   0x0803 — Oracle pricing
///   0x0804 — Mark pricing

/// @notice Struct for perp position data
struct PerpPosition {
    uint32 asset;
    int256 size;       // positive = long, negative = short
    uint256 entryNotional;
    uint256 leverage;
}

/// @notice Struct for spot balance data
struct SpotBalance {
    address token;
    uint256 total;
    uint256 held;
    uint256 entryNotional;
}

/// @notice Struct for margin summary
struct MarginSummary {
    uint256 accountValue;
    uint256 totalMarginUsed;
    uint256 withdrawable;
}
