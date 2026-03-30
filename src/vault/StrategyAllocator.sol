// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategy} from "../strategy/IStrategy.sol";

/// @title StrategyAllocator
/// @notice Risk-tier based capital allocation engine for NomadAutoVault
/// @dev Manages multiple strategies with configurable weight profiles per risk tier.
///      Risk Tiers:
///        0 = Conservative (low risk, steady yield)
///        1 = Moderate (balanced risk/reward)
///        2 = Aggressive (high yield, higher risk)
contract StrategyAllocator is Ownable {
    uint256 public constant MAX_STRATEGIES = 10;
    uint256 public constant BPS_BASE = 10000;

    struct StrategyConfig {
        IStrategy strategy;
        string name;
        bool active;
    }

    struct RiskProfile {
        string name;
        uint256[] weights;  // Weight per strategy index (bps, must sum to 10000)
        bool active;
    }

    StrategyConfig[] public strategies;
    mapping(uint256 => RiskProfile) public riskProfiles; // tier => profile
    uint256 public activeRiskTier;

    event StrategyAdded(uint256 indexed index, address strategy, string name);
    event StrategyRemoved(uint256 indexed index);
    event RiskProfileUpdated(uint256 indexed tier, string name);
    event AllocationExecuted(uint256 indexed tier, uint256 totalAmount);

    constructor(address owner_) Ownable(owner_) {}

    // ========================================================================
    //                      STRATEGY MANAGEMENT
    // ========================================================================

    function addStrategy(address strategy_, string calldata name_) external onlyOwner returns (uint256 index) {
        require(strategies.length < MAX_STRATEGIES, "Max strategies");
        strategies.push(StrategyConfig({
            strategy: IStrategy(strategy_),
            name: name_,
            active: true
        }));
        index = strategies.length - 1;
        emit StrategyAdded(index, strategy_, name_);
    }

    function removeStrategy(uint256 index) external onlyOwner {
        require(index < strategies.length, "Invalid index");
        require(strategies[index].strategy.totalDeployedAssets() == 0, "Has deployed assets");
        strategies[index].active = false;
        emit StrategyRemoved(index);
    }

    function strategyCount() external view returns (uint256) {
        return strategies.length;
    }

    // ========================================================================
    //                      RISK PROFILE MANAGEMENT
    // ========================================================================

    /// @notice Set a risk profile with allocation weights
    /// @param tier Risk tier (0=Conservative, 1=Moderate, 2=Aggressive)
    /// @param name_ Profile name
    /// @param weights_ Weight per strategy (bps, must sum to BPS_BASE or less)
    function setRiskProfile(
        uint256 tier,
        string calldata name_,
        uint256[] calldata weights_
    ) external onlyOwner {
        require(weights_.length == strategies.length, "Weight count mismatch");

        uint256 totalWeight;
        for (uint256 i = 0; i < weights_.length; i++) {
            totalWeight += weights_[i];
        }
        require(totalWeight <= BPS_BASE, "Weights exceed 100%");

        riskProfiles[tier] = RiskProfile({
            name: name_,
            weights: weights_,
            active: true
        });

        emit RiskProfileUpdated(tier, name_);
    }

    function setActiveRiskTier(uint256 tier) external onlyOwner {
        require(riskProfiles[tier].active, "Tier not configured");
        activeRiskTier = tier;
    }

    // ========================================================================
    //                      ALLOCATION ENGINE
    // ========================================================================

    /// @notice Calculate how much to allocate to each strategy for a given amount
    /// @param totalAmount Total USDC to allocate
    /// @return amounts Amount for each strategy index
    function calculateAllocation(uint256 totalAmount) external view returns (uint256[] memory amounts) {
        RiskProfile storage profile = riskProfiles[activeRiskTier];
        require(profile.active, "No active risk profile");

        amounts = new uint256[](strategies.length);
        uint256 allocated;

        for (uint256 i = 0; i < strategies.length; i++) {
            if (!strategies[i].active || i >= profile.weights.length) continue;
            amounts[i] = (totalAmount * profile.weights[i]) / BPS_BASE;
            allocated += amounts[i];
        }

        // Dust to first active strategy
        if (allocated < totalAmount && strategies.length > 0) {
            for (uint256 i = 0; i < strategies.length; i++) {
                if (strategies[i].active && amounts[i] > 0) {
                    amounts[i] += totalAmount - allocated;
                    break;
                }
            }
        }
    }

    /// @notice Get the strategy address at a given index
    function getStrategy(uint256 index) external view returns (IStrategy) {
        require(index < strategies.length, "Invalid index");
        return strategies[index].strategy;
    }

    /// @notice Check if a strategy is active
    function isActive(uint256 index) external view returns (bool) {
        return index < strategies.length && strategies[index].active;
    }

    /// @notice Get current risk profile weights
    function getWeights(uint256 tier) external view returns (uint256[] memory) {
        return riskProfiles[tier].weights;
    }

    /// @notice Get total deployed across all strategies
    function totalDeployed() external view returns (uint256 total) {
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i].active) {
                total += strategies[i].strategy.totalDeployedAssets();
            }
        }
    }

    /// @notice Get aggregate net delta across all strategies
    function aggregateNetDelta() external view returns (int256 delta) {
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i].active) {
                delta += strategies[i].strategy.netDelta();
            }
        }
    }

    /// @notice Get weighted average estimated APR
    function weightedAPR() external view returns (uint256 apr) {
        RiskProfile storage profile = riskProfiles[activeRiskTier];
        if (!profile.active) return 0;

        uint256 totalWeight;
        for (uint256 i = 0; i < strategies.length; i++) {
            if (!strategies[i].active || i >= profile.weights.length || profile.weights[i] == 0) continue;
            apr += strategies[i].strategy.estimatedAPR() * profile.weights[i];
            totalWeight += profile.weights[i];
        }
        if (totalWeight > 0) apr = apr / totalWeight;
    }
}
