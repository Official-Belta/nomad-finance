// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICoreWriter
/// @notice Interface for HyperCore CoreWriter — places perp orders from HyperEVM
/// @dev CoreWriter address: 0x3333333333333333333333333333333333333333
interface ICoreWriter {
    /// @notice Send raw action bytes to HyperCore
    function sendRawAction(bytes calldata data) external;
}
