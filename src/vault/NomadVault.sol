// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategy} from "../strategy/IStrategy.sol";

/// @title NomadVault
/// @notice ERC-4626 vault with pluggable strategy, hedge, and risk modules
contract NomadVault is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    IStrategy public strategy;

    event StrategyUpdated(address indexed oldStrategy, address indexed newStrategy);

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address owner_
    ) ERC4626(asset_) ERC20(name_, symbol_) Ownable(owner_) {}

    /// @notice Set the active strategy
    function setStrategy(IStrategy newStrategy) external onlyOwner {
        address old = address(strategy);
        strategy = newStrategy;
        emit StrategyUpdated(old, address(newStrategy));
    }

    /// @notice Total assets under management including strategy positions
    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 deployed = address(strategy) != address(0) ? strategy.totalDeployedAssets() : 0;
        return idle + deployed;
    }
}
