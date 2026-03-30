// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategy} from "../strategy/IStrategy.sol";
import {StrategyAllocator} from "./StrategyAllocator.sol";
import {RiskManager} from "../risk/RiskManager.sol";

/// @title NomadAutoVault
/// @notice Phase 2 multi-strategy ERC-4626 vault with automatic risk-tier allocation
/// @dev "USDC 넣으면 알아서 분배. 리스크 티어 선택하면 끝."
///
///      Architecture:
///        User → USDC → NomadAutoVault → StrategyAllocator
///                                         ├── CoveredCall   (weight: 40%)
///                                         ├── CashSecuredPut (weight: 20%)
///                                         ├── IronCondor     (weight: 25%)
///                                         ├── BullCallSpread (weight: 10%)
///                                         └── Straddle       (weight: 5%)
///
///      Risk Tiers:
///        Conservative: 70% CC + 20% CSP + 10% idle
///        Moderate: 50% CC + 30% IC + 20% CSP
///        Aggressive: 40% CC + 30% IC + 20% BCS + 10% Straddle
contract NomadAutoVault is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    // --- Dependencies ---
    StrategyAllocator public allocator;
    RiskManager public riskManager;

    // --- Epoch ---
    uint256 public currentEpoch;
    uint256 public epochDuration;
    uint256 public epochStartTime;

    // --- Fees ---
    uint256 public performanceFeeBps;
    uint256 public managementFeeBps;
    uint256 public earlyExitFeeBps;
    address public feeRecipient;

    // --- Limits ---
    uint256 public depositCap;

    // --- Tracking ---
    uint256 public lastTotalAssets;      // For performance fee calculation
    uint256 public totalEpochsCompleted;

    // --- Events ---
    event EpochRolled(uint256 indexed epoch, uint256 profit, uint256 timestamp);
    event FeesCollected(uint256 performanceFee, uint256 managementFee);
    event Rebalanced(uint256 indexed epoch, uint256 totalDeployed);
    event EmergencyShutdown(uint256 timestamp);

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address owner_,
        address allocator_,
        address riskManager_,
        uint256 epochDuration_,
        uint256 depositCap_
    ) ERC4626(asset_) ERC20(name_, symbol_) Ownable(owner_) {
        allocator = StrategyAllocator(allocator_);
        riskManager = RiskManager(riskManager_);
        epochDuration = epochDuration_;
        depositCap = depositCap_;
        performanceFeeBps = 1500;
        managementFeeBps = 150;
        earlyExitFeeBps = 50;
        feeRecipient = owner_;
    }

    // ========================================================================
    //                        EPOCH MANAGEMENT
    // ========================================================================

    /// @notice Roll epoch: harvest all strategies, collect fees, rebalance
    function rollEpoch() external onlyOwner {
        require(block.timestamp >= epochStartTime + epochDuration, "Epoch not ended");

        uint256 preAssets = totalAssets();

        // 1. Harvest all active strategies
        uint256 totalProfit = _harvestAll();

        // 2. Collect fees on profit
        if (totalProfit > 0) {
            uint256 perfFee = (totalProfit * performanceFeeBps) / 10000;
            if (perfFee > 0) {
                IERC20(asset()).safeTransfer(feeRecipient, perfFee);
            }

            // Management fee (annualized, pro-rata for epoch)
            uint256 mgmtFee = (preAssets * managementFeeBps * epochDuration) / (10000 * 365.25 days);
            if (mgmtFee > 0) {
                uint256 available = IERC20(asset()).balanceOf(address(this));
                if (mgmtFee > available) mgmtFee = available;
                IERC20(asset()).safeTransfer(feeRecipient, mgmtFee);
            }

            emit FeesCollected(totalProfit * performanceFeeBps / 10000, mgmtFee);
        }

        // 3. Rebalance across strategies according to current risk tier
        _rebalance();

        // 4. Update epoch state
        lastTotalAssets = totalAssets();
        currentEpoch++;
        totalEpochsCompleted++;
        epochStartTime = block.timestamp;

        // 5. Update risk manager NAV
        riskManager.updateNAV(lastTotalAssets);

        emit EpochRolled(currentEpoch, totalProfit, block.timestamp);
    }

    /// @notice Force rebalance without rolling epoch (e.g., after risk tier change)
    function rebalance() external onlyOwner {
        _rebalance();
    }

    // ========================================================================
    //                     ERC-4626 OVERRIDES
    // ========================================================================

    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 deployed = allocator.totalDeployed();
        return idle + deployed;
    }

    function maxDeposit(address) public view override returns (uint256) {
        uint256 currentAssets = totalAssets();
        if (currentAssets >= depositCap) return 0;
        return depositCap - currentAssets;
    }

    /// @notice Override deposit to auto-allocate into strategies
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        super._deposit(caller, receiver, assets, shares);

        // Auto-deploy into strategies based on allocator weights
        _deployToStrategies(assets);
    }

    /// @notice Mid-epoch withdrawal incurs early exit fee
    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal override {
        // Pull from strategies if insufficient idle balance
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets) {
            uint256 needed = assets - idle;
            _withdrawFromStrategies(needed);
        }

        bool midEpoch = block.timestamp < epochStartTime + epochDuration;
        if (midEpoch && earlyExitFeeBps > 0) {
            uint256 fee = (assets * earlyExitFeeBps) / 10000;
            assets -= fee; // fee stays in vault
        }

        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    // ========================================================================
    //                       STRATEGY INTERACTION
    // ========================================================================

    /// @dev Deploy USDC to strategies according to allocator weights
    function _deployToStrategies(uint256 totalAmount) internal {
        uint256[] memory amounts = allocator.calculateAllocation(totalAmount);

        for (uint256 i = 0; i < amounts.length; i++) {
            if (amounts[i] == 0) continue;
            if (!allocator.isActive(i)) continue;

            IStrategy strategy = allocator.getStrategy(i);
            IERC20(asset()).approve(address(strategy), amounts[i]);
            strategy.deposit(amounts[i]);
        }
    }

    /// @dev Withdraw from strategies (proportionally)
    function _withdrawFromStrategies(uint256 needed) internal {
        uint256 totalDeployed = allocator.totalDeployed();
        if (totalDeployed == 0) return;

        uint256 count = allocator.strategyCount();
        for (uint256 i = 0; i < count; i++) {
            if (!allocator.isActive(i)) continue;

            IStrategy strategy = allocator.getStrategy(i);
            uint256 deployed = strategy.totalDeployedAssets();
            if (deployed == 0) continue;

            // Proportional withdrawal
            uint256 withdrawAmount = (needed * deployed) / totalDeployed;
            if (withdrawAmount > 0) {
                strategy.withdraw(withdrawAmount);
            }
        }
    }

    /// @dev Harvest all strategies and return total profit
    function _harvestAll() internal returns (uint256 totalProfit) {
        uint256 count = allocator.strategyCount();
        for (uint256 i = 0; i < count; i++) {
            if (!allocator.isActive(i)) continue;
            IStrategy strategy = allocator.getStrategy(i);
            totalProfit += strategy.harvest();
        }
    }

    /// @dev Rebalance: withdraw all, then redeploy according to current weights
    function _rebalance() internal {
        uint256 count = allocator.strategyCount();

        // Phase 1: Withdraw everything from all strategies
        for (uint256 i = 0; i < count; i++) {
            if (!allocator.isActive(i)) continue;
            IStrategy strategy = allocator.getStrategy(i);
            uint256 deployed = strategy.totalDeployedAssets();
            if (deployed > 0) {
                strategy.withdraw(deployed);
            }
        }

        // Phase 2: Redeploy according to current allocation weights
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle > 0) {
            _deployToStrategies(idle);
        }

        emit Rebalanced(currentEpoch, allocator.totalDeployed());
    }

    // ========================================================================
    //                        EMERGENCY
    // ========================================================================

    /// @notice Emergency shutdown — close all positions across all strategies
    function emergencyShutdown() external onlyOwner {
        uint256 count = allocator.strategyCount();
        for (uint256 i = 0; i < count; i++) {
            if (!allocator.isActive(i)) continue;
            try allocator.getStrategy(i).emergencyClose() {} catch {}
        }
        emit EmergencyShutdown(block.timestamp);
    }

    // ========================================================================
    //                         VIEW FUNCTIONS
    // ========================================================================

    /// @notice Get estimated blended APR across all strategies
    function estimatedAPR() external view returns (uint256) {
        return allocator.weightedAPR();
    }

    /// @notice Get aggregate portfolio delta
    function portfolioDelta() external view returns (int256) {
        return allocator.aggregateNetDelta();
    }

    /// @notice Get risk score from RiskManager
    function riskScore() external view returns (uint256) {
        return riskManager.riskScore();
    }

    /// @notice Get current risk tier name
    function currentRiskTier() external view returns (uint256) {
        return allocator.activeRiskTier();
    }

    // ========================================================================
    //                          ADMIN
    // ========================================================================

    function setAllocator(address newAllocator) external onlyOwner {
        allocator = StrategyAllocator(newAllocator);
    }

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

    function setEpochDuration(uint256 newDuration) external onlyOwner {
        require(newDuration >= 1 days && newDuration <= 90 days, "1-90 days");
        epochDuration = newDuration;
    }
}
