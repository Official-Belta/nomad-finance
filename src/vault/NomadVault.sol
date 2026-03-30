// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategy} from "../strategy/IStrategy.sol";

/// @title NomadVault
/// @notice ERC-4626 vault with epoch-based option strategy management
/// @dev Deposits USDC → Strategy deploys to Rysk RFQ → Premium collected → Auto-roll
contract NomadVault is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    // --- State ---
    IStrategy public strategy;

    uint256 public currentEpoch;
    uint256 public epochDuration;       // e.g. 7 days
    uint256 public epochStartTime;

    uint256 public performanceFeeBps;   // e.g. 1000 = 10%
    uint256 public managementFeeBps;    // e.g. 200  = 2%
    uint256 public earlyExitFeeBps;     // e.g. 50   = 0.5%
    address public feeRecipient;

    uint256 public depositCap;          // Max TVL cap

    // --- Events ---
    event StrategyUpdated(address indexed oldStrategy, address indexed newStrategy);
    event EpochRolled(uint256 indexed epoch, uint256 timestamp);
    event FeesCollected(uint256 performanceFee, uint256 managementFee);

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address owner_,
        uint256 epochDuration_,
        uint256 depositCap_
    ) ERC4626(asset_) ERC20(name_, symbol_) Ownable(owner_) {
        epochDuration = epochDuration_;
        depositCap = depositCap_;
        performanceFeeBps = 1500;   // 15% default
        managementFeeBps = 150;     // 1.5% default
        earlyExitFeeBps = 50;       // 0.5% default
        feeRecipient = owner_;
    }

    // --- Strategy Management ---

    function setStrategy(IStrategy newStrategy) external onlyOwner {
        address old = address(strategy);
        strategy = newStrategy;
        emit StrategyUpdated(old, address(newStrategy));
    }

    // --- Epoch Management ---

    /// @notice Roll to the next epoch — settle, collect fees, auto-roll positions
    function rollEpoch() external onlyOwner {
        require(block.timestamp >= epochStartTime + epochDuration, "Epoch not ended");

        if (address(strategy) != address(0)) {
            uint256 profit = strategy.harvest();
            if (profit > 0) {
                uint256 perfFee = (profit * performanceFeeBps) / 10000;
                IERC20(asset()).safeTransfer(feeRecipient, perfFee);
                emit FeesCollected(perfFee, 0);
            }
        }

        currentEpoch++;
        epochStartTime = block.timestamp;
        emit EpochRolled(currentEpoch, block.timestamp);
    }

    // --- ERC-4626 Overrides ---

    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 deployed = address(strategy) != address(0) ? strategy.totalDeployedAssets() : 0;
        return idle + deployed;
    }

    function maxDeposit(address) public view override returns (uint256) {
        uint256 currentAssets = totalAssets();
        if (currentAssets >= depositCap) return 0;
        return depositCap - currentAssets;
    }

    /// @notice Mid-epoch withdrawal incurs early exit fee
    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal override {
        bool midEpoch = block.timestamp < epochStartTime + epochDuration;
        if (midEpoch && earlyExitFeeBps > 0) {
            uint256 fee = (assets * earlyExitFeeBps) / 10000;
            assets -= fee;
            // Fee stays in vault (benefits remaining depositors)
        }
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    // --- Admin ---

    function setFees(uint256 perfBps, uint256 mgmtBps, uint256 exitBps) external onlyOwner {
        require(perfBps <= 2000, "Max 20%");
        require(mgmtBps <= 200, "Max 2%");
        require(exitBps <= 100, "Max 1%");
        performanceFeeBps = perfBps;
        managementFeeBps = mgmtBps;
        earlyExitFeeBps = exitBps;
    }

    function setDepositCap(uint256 newCap) external onlyOwner {
        depositCap = newCap;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Zero address");
        feeRecipient = newRecipient;
    }
}
