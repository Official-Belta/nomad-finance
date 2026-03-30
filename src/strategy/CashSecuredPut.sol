// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategy} from "./IStrategy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRyskRFQ} from "../interfaces/rysk/IRyskRFQ.sol";
import {ICiao} from "../interfaces/rysk/ICiao.sol";
import {PricingEngine} from "../pricing/PricingEngine.sol";
import {DeltaHedger} from "../hedge/DeltaHedger.sol";
import {RiskManager} from "../risk/RiskManager.sol";

/// @title CashSecuredPut
/// @notice Cash-Secured Put strategy — hold USDC + sell put options via Rysk RFQ
/// @dev Phase 1 strategy. Target APR: 18-50%.
///      Flow: deposit USDC collateral → sell OTM put via Rysk → collect premium → delta hedge
contract CashSecuredPut is IStrategy, Ownable {
    using SafeERC20 for IERC20;

    // --- External dependencies ---
    IERC20 public immutable usdc;
    address public vault;
    IRyskRFQ public ryskRFQ;
    ICiao public ciao;
    PricingEngine public pricingEngine;
    DeltaHedger public deltaHedger;
    RiskManager public riskManager;

    // --- Strategy parameters ---
    uint256 public deployedAssets;
    uint256 public targetDelta;         // e.g. 25 = 0.25 |delta|
    uint256 public expiryDuration;
    address public underlyingAsset;
    uint32 public hedgeAssetId;
    uint256 public ciaoSubAccountId;
    uint256 public minPremiumBps;       // Min acceptable premium vs BSM

    // --- Position tracking ---
    struct Position {
        uint256 strike;
        uint256 expiry;
        uint256 size;
        uint256 premiumCollected;
        bytes32 quoteId;
        bytes32 hedgeId;
        bool settled;
    }
    Position[] public positions;
    uint256 public totalPremiumCollected;

    event OptionSold(uint256 indexed positionId, uint256 strike, uint256 expiry, uint256 premium, bytes32 quoteId);
    event PositionSettled(uint256 indexed positionId, uint256 premium);

    modifier onlyVault() {
        require(msg.sender == vault, "Only vault");
        _;
    }

    constructor(
        address usdc_,
        address vault_,
        address owner_,
        address ryskRFQ_,
        address ciao_,
        address pricingEngine_,
        address deltaHedger_,
        address riskManager_
    ) Ownable(owner_) {
        usdc = IERC20(usdc_);
        vault = vault_;
        ryskRFQ = IRyskRFQ(ryskRFQ_);
        ciao = ICiao(ciao_);
        pricingEngine = PricingEngine(pricingEngine_);
        deltaHedger = DeltaHedger(deltaHedger_);
        riskManager = RiskManager(riskManager_);

        targetDelta = 25;
        expiryDuration = 7 days;
        minPremiumBps = 9000;
    }

    // ========================================================================
    //                        CORE STRATEGY FLOW
    // ========================================================================

    function deposit(uint256 amount) external onlyVault {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        deployedAssets += amount;

        // 1. Deposit collateral into Rysk Ciao
        usdc.approve(address(ciao), amount);
        ciao.deposit(ciaoSubAccountId, amount);

        // 2. Get optimal OTM put strike
        uint256 spot = _getSpotPrice();
        uint256 vol = pricingEngine.getBlendedVol(underlyingAsset);
        if (vol == 0) vol = 0.8e18;

        uint256 strike = pricingEngine.findStrikeByDelta(
            spot, vol, expiryDuration,
            targetDelta * 100, // bps
            false              // isPut
        );

        // 3. BSM fair value for premium validation
        uint256 bsmPrice = pricingEngine.bsmPutPrice(spot, strike, vol, expiryDuration, 0);

        // 4. Submit put sell quote to Rysk RFQ
        uint256 expiry = block.timestamp + expiryDuration;
        IRyskRFQ.OptionQuote memory quote = IRyskRFQ.OptionQuote({
            assetAddress: underlyingAsset,
            strike: strike,
            expiry: expiry,
            isPut: true,
            isTakerBuy: true,
            price: bsmPrice,
            quantity: amount,
            collateralAsset: address(usdc),
            validUntil: block.timestamp + 5 minutes,
            nonce: uint256(keccak256(abi.encodePacked(block.timestamp, positions.length)))
        });
        bytes32 quoteId = ryskRFQ.submitQuote(quote, "");

        // 5. Risk check
        int256 positionDelta = pricingEngine.calcDelta(spot, strike, vol, expiryDuration, false);
        (bool allowed, string memory reason) = riskManager.checkRisk(
            amount, deployedAssets, -positionDelta // short put = positive delta
        );
        require(allowed, reason);

        // 6. Delta hedge — short put has positive delta → hedge by shorting perp
        int256 hedgeSize = positionDelta * int256(amount) / 1e18; // negative (short perp)
        bytes32 hedgeId;
        if (hedgeSize != 0) {
            hedgeId = deltaHedger.openHedge(
                hedgeAssetId, hedgeSize,
                uint64(uint256(spot / 1e10))
            );
        }

        // 7. Record position
        positions.push(Position({
            strike: strike,
            expiry: expiry,
            size: amount,
            premiumCollected: 0,
            quoteId: quoteId,
            hedgeId: hedgeId,
            settled: false
        }));

        emit OptionSold(positions.length - 1, strike, expiry, bsmPrice, quoteId);
    }

    function harvest() external onlyVault returns (uint256 profit) {
        uint256 totalProfit;

        for (uint256 i = 0; i < positions.length; i++) {
            Position storage pos = positions[i];
            if (pos.settled || block.timestamp < pos.expiry) continue;

            ciao.settleCoreCollateral(ciaoSubAccountId);
            uint256 balance = ciao.getBalance(address(this), ciaoSubAccountId);

            if (pos.hedgeId != bytes32(0)) {
                deltaHedger.closeHedge(pos.hedgeId);
            }

            if (balance > 0) {
                ciao.requestWithdrawal(ciaoSubAccountId, balance);
            }

            pos.settled = true;
            pos.premiumCollected = balance > pos.size ? balance - pos.size : 0;
            totalProfit += pos.premiumCollected;
            totalPremiumCollected += pos.premiumCollected;

            emit PositionSettled(i, pos.premiumCollected);
        }

        if (totalProfit > 0) {
            uint256 available = usdc.balanceOf(address(this));
            uint256 toTransfer = totalProfit > available ? available : totalProfit;
            if (toTransfer > 0) usdc.safeTransfer(vault, toTransfer);
        }

        profit = totalProfit;
    }

    function withdraw(uint256 amount) external onlyVault returns (uint256) {
        uint256 available = usdc.balanceOf(address(this));
        uint256 toWithdraw = amount > available ? available : amount;
        deployedAssets = deployedAssets > toWithdraw ? deployedAssets - toWithdraw : 0;
        usdc.safeTransfer(vault, toWithdraw);
        return toWithdraw;
    }

    function totalDeployedAssets() external view returns (uint256) {
        return deployedAssets;
    }

    function estimatedAPR() external view returns (uint256) {
        if (deployedAssets == 0 || positions.length == 0) return 3000;
        uint256 lastPremium;
        for (uint256 i = positions.length; i > 0; i--) {
            if (positions[i - 1].settled && positions[i - 1].premiumCollected > 0) {
                lastPremium = positions[i - 1].premiumCollected;
                break;
            }
        }
        if (lastPremium == 0) return 3000;
        uint256 epochsPerYear = (365 days * 10000) / expiryDuration;
        return (lastPremium * epochsPerYear) / deployedAssets;
    }

    function netDelta() external view returns (int256 delta) {
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].settled) continue;
            Position storage pos = positions[i];
            uint256 timeLeft = pos.expiry > block.timestamp ? pos.expiry - block.timestamp : 0;
            if (timeLeft == 0) continue;

            uint256 vol = pricingEngine.getBlendedVol(underlyingAsset);
            if (vol == 0) vol = 0.8e18;

            int256 optDelta = pricingEngine.calcDelta(
                _getSpotPrice(), pos.strike, vol, timeLeft, false
            );
            delta -= optDelta * int256(pos.size) / 1e18; // short put
        }
        delta += deltaHedger.netDelta();
    }

    function emergencyClose() external onlyOwner {
        for (uint256 i = 0; i < positions.length; i++) {
            if (!positions[i].settled && positions[i].quoteId != bytes32(0)) {
                try ryskRFQ.cancelQuote(positions[i].quoteId) {} catch {}
                positions[i].settled = true;
            }
        }
        deltaHedger.emergencyCloseAll();

        uint256 ciaoBalance = ciao.getBalance(address(this), ciaoSubAccountId);
        if (ciaoBalance > 0) ciao.requestWithdrawal(ciaoSubAccountId, ciaoBalance);

        uint256 balance = usdc.balanceOf(address(this));
        if (balance > 0) {
            usdc.safeTransfer(vault, balance);
            deployedAssets = 0;
        }
    }

    // --- Admin ---
    function setTargetDelta(uint256 d) external onlyOwner { require(d > 0 && d <= 50, "1-50"); targetDelta = d; }
    function setExpiryDuration(uint256 d) external onlyOwner { require(d >= 1 days && d <= 90 days, "1-90d"); expiryDuration = d; }
    function setUnderlyingAsset(address a) external onlyOwner { underlyingAsset = a; }
    function setHedgeAssetId(uint32 id) external onlyOwner { hedgeAssetId = id; }
    function setCiaoSubAccountId(uint256 id) external onlyOwner { ciaoSubAccountId = id; }
    function setMinPremiumBps(uint256 b) external onlyOwner { require(b >= 5000 && b <= 10000, "50-100%"); minPremiumBps = b; }

    // --- Internal ---
    function _getSpotPrice() internal view returns (uint256) {
        (bool ok, bytes memory data) = address(0x0803).staticcall(abi.encodePacked(hedgeAssetId));
        if (ok && data.length >= 32) return abi.decode(data, (uint256));
        revert("Oracle unavailable");
    }
}
