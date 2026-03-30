// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NomadVault} from "../src/vault/NomadVault.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract NomadVaultTest is Test {
    NomadVault public vault;
    ERC20Mock public asset;
    address public owner = address(this);
    address public alice = makeAddr("alice");

    function setUp() public {
        asset = new ERC20Mock();
        vault = new NomadVault(IERC20(address(asset)), "Nomad Vault", "nVAULT", owner);
    }

    function test_metadata() public view {
        assertEq(vault.name(), "Nomad Vault");
        assertEq(vault.symbol(), "nVAULT");
        assertEq(vault.asset(), address(asset));
    }

    function test_deposit() public {
        uint256 amount = 1e18;
        asset.mint(alice, amount);

        vm.startPrank(alice);
        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), amount);
    }

    function test_withdraw() public {
        uint256 amount = 1e18;
        asset.mint(alice, amount);

        vm.startPrank(alice);
        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);
        assertEq(asset.balanceOf(alice), amount);
    }

    function test_setStrategy_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setStrategy(IStrategyMock(address(0x1)));
    }
}

// Minimal mock for type checking
interface IStrategyMock {
    function totalDeployedAssets() external view returns (uint256);
}
