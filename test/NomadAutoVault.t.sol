// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NomadAutoVault} from "../src/vault/NomadAutoVault.sol";
import {StrategyAllocator} from "../src/vault/StrategyAllocator.sol";
import {RiskManager} from "../src/risk/RiskManager.sol";
import {IStrategy} from "../src/strategy/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @dev Simple mock strategy that accepts USDC and tracks balances
contract SimpleStrategy is IStrategy {
    IERC20 public usdc;
    uint256 public deployed;

    constructor(address usdc_) { usdc = IERC20(usdc_); }

    function deposit(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        deployed += amount;
    }

    function withdraw(uint256 amount) external returns (uint256) {
        uint256 w = amount > deployed ? deployed : amount;
        deployed -= w;
        usdc.transfer(msg.sender, w);
        return w;
    }

    function harvest() external pure returns (uint256) { return 0; }
    function totalDeployedAssets() external view returns (uint256) { return deployed; }
    function estimatedAPR() external pure returns (uint256) { return 3000; }
    function netDelta() external pure returns (int256) { return 0; }
    function emergencyClose() external {
        uint256 bal = usdc.balanceOf(address(this));
        if (bal > 0) usdc.transfer(msg.sender, bal);
        deployed = 0;
    }
}

contract NomadAutoVaultTest is Test {
    NomadAutoVault public vault;
    StrategyAllocator public allocator;
    RiskManager public riskManager;
    ERC20Mock public usdc;

    SimpleStrategy public strategyA;
    SimpleStrategy public strategyB;

    address public owner = address(this);
    address public alice = makeAddr("alice");

    uint256 constant EPOCH = 7 days;
    uint256 constant CAP = 5_000_000e18;

    function setUp() public {
        usdc = new ERC20Mock();
        allocator = new StrategyAllocator(owner);
        riskManager = new RiskManager(owner);

        vault = new NomadAutoVault(
            IERC20(address(usdc)),
            "Nomad Auto Vault",
            "naVAULT",
            owner,
            address(allocator),
            address(riskManager),
            EPOCH,
            CAP
        );

        strategyA = new SimpleStrategy(address(usdc));
        strategyB = new SimpleStrategy(address(usdc));

        allocator.addStrategy(address(strategyA), "StrategyA");
        allocator.addStrategy(address(strategyB), "StrategyB");

        uint256[] memory weights = new uint256[](2);
        weights[0] = 6000;  // 60%
        weights[1] = 4000;  // 40%
        allocator.setRiskProfile(0, "Balanced", weights);
        allocator.setActiveRiskTier(0);
    }

    function test_metadata() public view {
        assertEq(vault.name(), "Nomad Auto Vault");
        assertEq(vault.symbol(), "naVAULT");
        assertEq(vault.depositCap(), CAP);
        assertEq(vault.epochDuration(), EPOCH);
    }

    function test_deposit_allocatesToStrategies() public {
        uint256 amount = 1000e18;
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        // 60% to A, 40% to B
        assertEq(strategyA.deployed(), 600e18);
        assertEq(strategyB.deployed(), 400e18);
        assertEq(vault.totalAssets(), amount);
    }

    function test_depositCap() public {
        usdc.mint(alice, CAP + 1e18);

        vm.startPrank(alice);
        usdc.approve(address(vault), CAP + 1e18);
        vault.deposit(CAP, alice);
        assertEq(vault.maxDeposit(alice), 0);
        vm.stopPrank();
    }

    function test_withdraw_pullsFromStrategies() public {
        uint256 amount = 1000e18;
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);

        // Withdraw all
        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        // Alice should have received funds (minus early exit fee)
        assertGt(usdc.balanceOf(alice), 0);
        assertLe(usdc.balanceOf(alice), amount); // early exit fee
    }

    function test_rollEpoch() public {
        uint256 amount = 1000e18;
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        // Warp past epoch
        vm.warp(block.timestamp + EPOCH + 1);

        vault.rollEpoch();
        assertEq(vault.currentEpoch(), 1);
        assertEq(vault.totalEpochsCompleted(), 1);
    }

    function test_rollEpoch_tooEarly() public {
        vm.expectRevert("Epoch not ended");
        vault.rollEpoch();
    }

    function test_emergencyShutdown() public {
        uint256 amount = 1000e18;
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        vault.emergencyShutdown();
        assertEq(strategyA.deployed(), 0);
        assertEq(strategyB.deployed(), 0);
    }

    function test_fees() public view {
        assertEq(vault.performanceFeeBps(), 1500);
        assertEq(vault.managementFeeBps(), 150);
        assertEq(vault.earlyExitFeeBps(), 50);
    }

    function test_setFees() public {
        vault.setFees(1000, 100, 30);
        assertEq(vault.performanceFeeBps(), 1000);
        assertEq(vault.managementFeeBps(), 100);
        assertEq(vault.earlyExitFeeBps(), 30);
    }

    function test_setFees_limits() public {
        vm.expectRevert("Max 20%");
        vault.setFees(2100, 100, 50);

        vm.expectRevert("Max 2%");
        vault.setFees(1000, 300, 50);

        vm.expectRevert("Max 1%");
        vault.setFees(1000, 100, 200);
    }

    function test_estimatedAPR() public view {
        // Weighted APR from mock strategies: (3000*6000 + 3000*4000) / 10000 = 3000
        assertEq(vault.estimatedAPR(), 3000);
    }

    function test_riskScore() public view {
        // No positions, risk score should be 0
        assertEq(vault.riskScore(), 0);
    }

    function test_portfolioDelta() public view {
        // Mock strategies return 0 delta
        assertEq(vault.portfolioDelta(), 0);
    }

    function test_setDepositCap() public {
        vault.setDepositCap(10_000_000e18);
        assertEq(vault.depositCap(), 10_000_000e18);
    }
}
