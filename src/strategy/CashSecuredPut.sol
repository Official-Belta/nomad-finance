// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategy} from "./IStrategy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CashSecuredPut
/// @notice Cash-Secured Put strategy — hold USDC + sell put options via Rysk RFQ
/// @dev Phase 1 strategy. Target APR: 18-50%.
///      Flow: deposit USDC as collateral → sell put via Rysk → collect premium → delta hedge
contract CashSecuredPut is IStrategy, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public vault;
    uint256 public deployedAssets;

    uint256 public targetDelta;     // e.g. 25 = -0.25 delta
    uint256 public expiryDuration;

    event OptionSold(uint256 strike, uint256 expiry, uint256 premium);

    modifier onlyVault() {
        require(msg.sender == vault, "Only vault");
        _;
    }

    constructor(address usdc_, address vault_, address owner_) Ownable(owner_) {
        usdc = IERC20(usdc_);
        vault = vault_;
        targetDelta = 25;
        expiryDuration = 7 days;
    }

    function deposit(uint256 amount) external onlyVault {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        deployedAssets += amount;
        // TODO: Sell put option via Rysk RFQ
    }

    function withdraw(uint256 amount) external onlyVault returns (uint256) {
        uint256 available = usdc.balanceOf(address(this));
        uint256 toWithdraw = amount > available ? available : amount;
        deployedAssets -= toWithdraw;
        usdc.safeTransfer(vault, toWithdraw);
        return toWithdraw;
    }

    function harvest() external onlyVault returns (uint256) {
        // TODO: Settle expired puts, collect premium
        return 0;
    }

    function totalDeployedAssets() external view returns (uint256) {
        return deployedAssets;
    }

    function estimatedAPR() external pure returns (uint256) {
        return 3000; // 30% target APR placeholder
    }

    function netDelta() external pure returns (int256) {
        return 0;
    }

    function emergencyClose() external onlyOwner {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance > 0) {
            usdc.safeTransfer(vault, balance);
            deployedAssets = 0;
        }
    }

    function setTargetDelta(uint256 newDelta) external onlyOwner {
        require(newDelta > 0 && newDelta <= 50, "Delta 1-50");
        targetDelta = newDelta;
    }
}
