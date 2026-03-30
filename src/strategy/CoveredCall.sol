// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategy} from "./IStrategy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CoveredCall
/// @notice Covered Call strategy — hold underlying + sell call options via Rysk RFQ
/// @dev Phase 1 strategy. Target APR: 20-55%.
///      Flow: deposit collateral → sell call via Rysk → collect premium → delta hedge via HyperCore
contract CoveredCall is IStrategy, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public vault;
    uint256 public deployedAssets;

    // Option parameters
    uint256 public targetDelta;     // e.g. 25 = 0.25 delta (moderate risk tier)
    uint256 public expiryDuration;  // e.g. 7 days

    // Position tracking
    struct Position {
        uint256 strike;
        uint256 expiry;
        uint256 size;
        uint256 premiumCollected;
        bool settled;
    }
    Position[] public positions;

    event OptionSold(uint256 indexed positionId, uint256 strike, uint256 expiry, uint256 premium);
    event PositionSettled(uint256 indexed positionId, int256 pnl);

    modifier onlyVault() {
        require(msg.sender == vault, "Only vault");
        _;
    }

    constructor(address usdc_, address vault_, address owner_) Ownable(owner_) {
        usdc = IERC20(usdc_);
        vault = vault_;
        targetDelta = 25;                  // Conservative: 0.25 delta
        expiryDuration = 7 days;
    }

    function deposit(uint256 amount) external onlyVault {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        deployedAssets += amount;
        // TODO: Sell call option via Rysk RFQ
        // TODO: Open delta hedge on HyperCore
    }

    function withdraw(uint256 amount) external onlyVault returns (uint256) {
        uint256 available = usdc.balanceOf(address(this));
        uint256 toWithdraw = amount > available ? available : amount;
        deployedAssets -= toWithdraw;
        usdc.safeTransfer(vault, toWithdraw);
        return toWithdraw;
    }

    function harvest() external onlyVault returns (uint256 profit) {
        // TODO: Settle expired options via Rysk
        // TODO: Collect premium
        // TODO: Re-hedge delta
        return 0;
    }

    function totalDeployedAssets() external view returns (uint256) {
        return deployedAssets;
    }

    function estimatedAPR() external pure returns (uint256) {
        return 3500; // 35% target APR placeholder
    }

    function netDelta() external pure returns (int256) {
        // TODO: Calculate from option positions + hedge positions
        return 0;
    }

    function emergencyClose() external onlyOwner {
        // TODO: Close all Rysk positions
        // TODO: Close all HyperCore hedges
        // TODO: Return all USDC to vault
        uint256 balance = usdc.balanceOf(address(this));
        if (balance > 0) {
            usdc.safeTransfer(vault, balance);
            deployedAssets = 0;
        }
    }

    // --- Admin ---

    function setTargetDelta(uint256 newDelta) external onlyOwner {
        require(newDelta > 0 && newDelta <= 50, "Delta 1-50");
        targetDelta = newDelta;
    }

    function setExpiryDuration(uint256 newDuration) external onlyOwner {
        expiryDuration = newDuration;
    }
}
