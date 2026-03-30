// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StrategyAllocator} from "../src/vault/StrategyAllocator.sol";
import {IStrategy} from "../src/strategy/IStrategy.sol";

/// @dev Mock strategy for testing
contract MockStrategy is IStrategy {
    uint256 public deployed;
    uint256 public apr;

    constructor(uint256 apr_) {
        apr = apr_;
    }

    function deposit(uint256 amount) external { deployed += amount; }
    function withdraw(uint256 amount) external returns (uint256) {
        uint256 w = amount > deployed ? deployed : amount;
        deployed -= w;
        return w;
    }
    function harvest() external pure returns (uint256) { return 0; }
    function totalDeployedAssets() external view returns (uint256) { return deployed; }
    function estimatedAPR() external view returns (uint256) { return apr; }
    function netDelta() external pure returns (int256) { return 0; }
    function emergencyClose() external { deployed = 0; }
}

contract StrategyAllocatorTest is Test {
    StrategyAllocator public allocator;
    MockStrategy public ccStrategy;
    MockStrategy public cspStrategy;
    MockStrategy public icStrategy;

    function setUp() public {
        allocator = new StrategyAllocator(address(this));

        ccStrategy = new MockStrategy(3500);   // 35% APR
        cspStrategy = new MockStrategy(3000);  // 30% APR
        icStrategy = new MockStrategy(2500);   // 25% APR

        allocator.addStrategy(address(ccStrategy), "CoveredCall");
        allocator.addStrategy(address(cspStrategy), "CashSecuredPut");
        allocator.addStrategy(address(icStrategy), "IronCondor");
    }

    function test_addStrategy() public view {
        assertEq(allocator.strategyCount(), 3);
    }

    function test_setRiskProfile_conservative() public {
        uint256[] memory weights = new uint256[](3);
        weights[0] = 7000;  // 70% CC
        weights[1] = 2000;  // 20% CSP
        weights[2] = 1000;  // 10% IC

        allocator.setRiskProfile(0, "Conservative", weights);
        allocator.setActiveRiskTier(0);

        uint256[] memory stored = allocator.getWeights(0);
        assertEq(stored[0], 7000);
        assertEq(stored[1], 2000);
        assertEq(stored[2], 1000);
    }

    function test_calculateAllocation() public {
        uint256[] memory weights = new uint256[](3);
        weights[0] = 5000;  // 50%
        weights[1] = 3000;  // 30%
        weights[2] = 2000;  // 20%

        allocator.setRiskProfile(1, "Moderate", weights);
        allocator.setActiveRiskTier(1);

        uint256[] memory amounts = allocator.calculateAllocation(1_000_000e18);
        assertEq(amounts[0], 500_000e18);
        assertEq(amounts[1], 300_000e18);
        assertEq(amounts[2], 200_000e18);
    }

    function test_calculateAllocation_withIdlePortion() public {
        uint256[] memory weights = new uint256[](3);
        weights[0] = 7000;  // 70%
        weights[1] = 2000;  // 20%
        weights[2] = 0;     // 0% — idle

        allocator.setRiskProfile(0, "Conservative", weights);
        allocator.setActiveRiskTier(0);

        uint256[] memory amounts = allocator.calculateAllocation(100e18);
        assertEq(amounts[0], 70e18);
        assertEq(amounts[1], 20e18);
        assertEq(amounts[2], 0);
        // 10% stays idle in vault
    }

    function test_removeStrategy_onlyIfEmpty() public {
        // Can remove if no deployed assets
        allocator.removeStrategy(2);
        assertFalse(allocator.isActive(2));
    }

    function test_removeStrategy_revertIfDeployed() public {
        ccStrategy.deposit(100e18); // simulate deployment
        vm.expectRevert("Has deployed assets");
        allocator.removeStrategy(0);
    }

    function test_weightedAPR() public {
        uint256[] memory weights = new uint256[](3);
        weights[0] = 5000;
        weights[1] = 3000;
        weights[2] = 2000;

        allocator.setRiskProfile(1, "Moderate", weights);
        allocator.setActiveRiskTier(1);

        uint256 apr = allocator.weightedAPR();
        // Expected: (3500*5000 + 3000*3000 + 2500*2000) / 10000 = (17.5M + 9M + 5M) / 10000 = 3150
        assertEq(apr, 3150);
    }

    function test_setRiskProfile_revertExcessWeight() public {
        uint256[] memory weights = new uint256[](3);
        weights[0] = 6000;
        weights[1] = 3000;
        weights[2] = 2000; // total = 11000 > 10000

        vm.expectRevert("Weights exceed 100%");
        allocator.setRiskProfile(0, "Bad", weights);
    }

    function test_maxStrategies() public {
        // Add up to MAX_STRATEGIES
        for (uint256 i = 3; i < 10; i++) {
            MockStrategy s = new MockStrategy(2000);
            allocator.addStrategy(address(s), "Extra");
        }
        assertEq(allocator.strategyCount(), 10);

        // 11th should fail
        MockStrategy extra = new MockStrategy(2000);
        vm.expectRevert("Max strategies");
        allocator.addStrategy(address(extra), "TooMany");
    }
}
