// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NomadVault} from "../src/vault/NomadVault.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStrategy} from "../src/strategy/IStrategy.sol";

contract NomadVaultTest is Test {
    NomadVault public vault;
    ERC20Mock public usdc;
    address public owner = address(this);
    address public alice = makeAddr("alice");

    uint256 constant EPOCH_DURATION = 7 days;
    uint256 constant DEPOSIT_CAP = 1_000_000e18; // $1M

    function setUp() public {
        usdc = new ERC20Mock();
        vault = new NomadVault(
            IERC20(address(usdc)),
            "Nomad Vault",
            "nVAULT",
            owner,
            EPOCH_DURATION,
            DEPOSIT_CAP
        );
    }

    function test_metadata() public view {
        assertEq(vault.name(), "Nomad Vault");
        assertEq(vault.symbol(), "nVAULT");
        assertEq(vault.asset(), address(usdc));
        assertEq(vault.epochDuration(), EPOCH_DURATION);
        assertEq(vault.depositCap(), DEPOSIT_CAP);
    }

    function test_fees() public view {
        assertEq(vault.performanceFeeBps(), 1500);
        assertEq(vault.managementFeeBps(), 150);
        assertEq(vault.earlyExitFeeBps(), 50);
    }

    function test_deposit() public {
        uint256 amount = 1000e18;
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), amount);
    }

    function test_depositCap() public {
        usdc.mint(alice, DEPOSIT_CAP + 1e18);

        vm.startPrank(alice);
        usdc.approve(address(vault), DEPOSIT_CAP + 1e18);
        vault.deposit(DEPOSIT_CAP, alice);

        // Should not allow exceeding cap
        assertEq(vault.maxDeposit(alice), 0);
        vm.stopPrank();
    }

    function test_withdraw() public {
        uint256 amount = 1000e18;
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);
        // Mid-epoch withdrawal has early exit fee
        assertLe(usdc.balanceOf(alice), amount);
    }

    function test_rollEpoch_tooEarly() public {
        vm.expectRevert("Epoch not ended");
        vault.rollEpoch();
    }

    function test_rollEpoch() public {
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        vault.rollEpoch();
        assertEq(vault.currentEpoch(), 1);
    }

    function test_setFees_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setFees(1000, 100, 50);
    }

    function test_setFees_maxLimits() public {
        vm.expectRevert("Max 20%");
        vault.setFees(2100, 100, 50);

        vm.expectRevert("Max 2%");
        vault.setFees(1000, 300, 50);

        vm.expectRevert("Max 1%");
        vault.setFees(1000, 100, 200);
    }

    function test_setStrategy_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setStrategy(IStrategy(address(0x1)));
    }
}
