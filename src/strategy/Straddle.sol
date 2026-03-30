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

/// @title Straddle
/// @notice Short Straddle strategy — sell ATM call + sell ATM put (vol play)
/// @dev Phase 2 strategy. Profits from low realized volatility.
///      Max profit = total premium collected (when spot ≈ strike at expiry).
///      Unlimited downside risk → requires aggressive delta hedging.
///      Best deployed when IV > realized vol forecast.
contract Straddle is IStrategy, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public vault;
    IRyskRFQ public ryskRFQ;
    ICiao public ciao;
    PricingEngine public pricingEngine;
    DeltaHedger public deltaHedger;
    RiskManager public riskManager;

    uint256 public deployedAssets;
    uint256 public expiryDuration;
    address public underlyingAsset;
    uint32 public hedgeAssetId;
    uint256 public ciaoSubAccountId;

    // Rehedge parameters — straddle requires frequent rebalancing
    uint256 public rehedgeThresholdBps;  // Delta deviation before rehedge (e.g. 300 = 3%)

    struct StraddlePosition {
        uint256 strike;          // ATM strike for both legs
        uint256 expiry;
        uint256 size;
        uint256 callPremium;
        uint256 putPremium;
        bytes32 callQuoteId;
        bytes32 putQuoteId;
        bytes32 hedgeId;
        bool settled;
        uint256 premiumCollected;
    }
    StraddlePosition[] public positions;
    uint256 public totalPremiumCollected;

    event StraddleOpened(uint256 indexed id, uint256 strike, uint256 totalPremium);
    event StraddleSettled(uint256 indexed id, uint256 premium);

    modifier onlyVault() {
        require(msg.sender == vault, "Only vault");
        _;
    }

    constructor(
        address usdc_, address vault_, address owner_,
        address ryskRFQ_, address ciao_, address pricingEngine_,
        address deltaHedger_, address riskManager_
    ) Ownable(owner_) {
        usdc = IERC20(usdc_);
        vault = vault_;
        ryskRFQ = IRyskRFQ(ryskRFQ_);
        ciao = ICiao(ciao_);
        pricingEngine = PricingEngine(pricingEngine_);
        deltaHedger = DeltaHedger(deltaHedger_);
        riskManager = RiskManager(riskManager_);

        expiryDuration = 7 days;
        rehedgeThresholdBps = 300; // 3%
    }

    function deposit(uint256 amount) external onlyVault {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        deployedAssets += amount;

        usdc.approve(address(ciao), amount);
        ciao.deposit(ciaoSubAccountId, amount);

        uint256 spot = _getSpotPrice();
        uint256 vol = pricingEngine.getBlendedVol(underlyingAsset);
        if (vol == 0) vol = 0.8e18;
        uint256 expiry = block.timestamp + expiryDuration;

        // ATM strike = spot price
        uint256 strike = spot;
        uint256 legSize = amount / 2;

        // BSM prices for both legs
        uint256 callPremium = pricingEngine.bsmCallPrice(spot, strike, vol, expiryDuration, 0);
        uint256 putPremium = pricingEngine.bsmPutPrice(spot, strike, vol, expiryDuration, 0);

        // Sell ATM call
        bytes32 callQuoteId = ryskRFQ.submitQuote(
            IRyskRFQ.OptionQuote({
                assetAddress: underlyingAsset,
                strike: strike,
                expiry: expiry,
                isPut: false,
                isTakerBuy: true,    // we sell
                price: callPremium,
                quantity: legSize,
                collateralAsset: address(usdc),
                validUntil: block.timestamp + 5 minutes,
                nonce: uint256(keccak256(abi.encodePacked(block.timestamp, "call")))
            }),
            ""
        );

        // Sell ATM put
        bytes32 putQuoteId = ryskRFQ.submitQuote(
            IRyskRFQ.OptionQuote({
                assetAddress: underlyingAsset,
                strike: strike,
                expiry: expiry,
                isPut: true,
                isTakerBuy: true,    // we sell
                price: putPremium,
                quantity: legSize,
                collateralAsset: address(usdc),
                validUntil: block.timestamp + 5 minutes,
                nonce: uint256(keccak256(abi.encodePacked(block.timestamp, "put")))
            }),
            ""
        );

        // ATM straddle: call delta ≈ 0.5, put delta ≈ -0.5 → net delta ≈ 0
        // Short straddle: flip signs → still ≈ 0
        // But gamma is very high at ATM, so need frequent rehedge
        int256 callDelta = pricingEngine.calcDelta(spot, strike, vol, expiryDuration, true);
        int256 putDelta_ = pricingEngine.calcDelta(spot, strike, vol, expiryDuration, false);
        int256 netPositionDelta = -(callDelta + putDelta_) * int256(legSize) / 1e18;

        (bool allowed, string memory reason) = riskManager.checkRisk(amount, deployedAssets, netPositionDelta);
        require(allowed, reason);

        // Hedge residual delta
        bytes32 hedgeId;
        if (netPositionDelta != 0) {
            hedgeId = deltaHedger.openHedge(hedgeAssetId, -netPositionDelta, uint64(uint256(spot / 1e10)));
        }

        positions.push(StraddlePosition({
            strike: strike,
            expiry: expiry,
            size: amount,
            callPremium: callPremium,
            putPremium: putPremium,
            callQuoteId: callQuoteId,
            putQuoteId: putQuoteId,
            hedgeId: hedgeId,
            settled: false,
            premiumCollected: 0
        }));

        emit StraddleOpened(positions.length - 1, strike, callPremium + putPremium);
    }

    function harvest() external onlyVault returns (uint256 profit) {
        uint256 totalProfit;
        for (uint256 i = 0; i < positions.length; i++) {
            StraddlePosition storage pos = positions[i];
            if (pos.settled || block.timestamp < pos.expiry) continue;

            ciao.settleCoreCollateral(ciaoSubAccountId);
            uint256 balance = ciao.getBalance(address(this), ciaoSubAccountId);

            if (pos.hedgeId != bytes32(0)) deltaHedger.closeHedge(pos.hedgeId);
            if (balance > 0) ciao.requestWithdrawal(ciaoSubAccountId, balance);

            pos.settled = true;
            pos.premiumCollected = balance > pos.size ? balance - pos.size : 0;
            totalProfit += pos.premiumCollected;
            totalPremiumCollected += pos.premiumCollected;

            emit StraddleSettled(i, pos.premiumCollected);
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

    function totalDeployedAssets() external view returns (uint256) { return deployedAssets; }

    function estimatedAPR() external view returns (uint256) {
        if (deployedAssets == 0 || positions.length == 0) return 4000; // 40% default (high premium)
        uint256 lastPremium;
        for (uint256 i = positions.length; i > 0; i--) {
            if (positions[i - 1].settled && positions[i - 1].premiumCollected > 0) {
                lastPremium = positions[i - 1].premiumCollected;
                break;
            }
        }
        if (lastPremium == 0) return 4000;
        return (lastPremium * (365 days * 10000) / expiryDuration) / deployedAssets;
    }

    function netDelta() external view returns (int256 delta) {
        uint256 vol = pricingEngine.getBlendedVol(underlyingAsset);
        if (vol == 0) vol = 0.8e18;
        uint256 spot = _getSpotPrice();

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].settled) continue;
            StraddlePosition storage pos = positions[i];
            uint256 timeLeft = pos.expiry > block.timestamp ? pos.expiry - block.timestamp : 0;
            if (timeLeft == 0) continue;

            int256 cd = pricingEngine.calcDelta(spot, pos.strike, vol, timeLeft, true);
            int256 pd = pricingEngine.calcDelta(spot, pos.strike, vol, timeLeft, false);
            delta -= (cd + pd) * int256(pos.size / 2) / 1e18; // short straddle
        }
        delta += deltaHedger.netDelta();
    }

    function emergencyClose() external onlyOwner {
        for (uint256 i = 0; i < positions.length; i++) {
            if (!positions[i].settled) {
                if (positions[i].callQuoteId != bytes32(0))
                    try ryskRFQ.cancelQuote(positions[i].callQuoteId) {} catch {}
                if (positions[i].putQuoteId != bytes32(0))
                    try ryskRFQ.cancelQuote(positions[i].putQuoteId) {} catch {}
                positions[i].settled = true;
            }
        }
        deltaHedger.emergencyCloseAll();
        uint256 ciaoBalance = ciao.getBalance(address(this), ciaoSubAccountId);
        if (ciaoBalance > 0) ciao.requestWithdrawal(ciaoSubAccountId, ciaoBalance);
        uint256 balance = usdc.balanceOf(address(this));
        if (balance > 0) { usdc.safeTransfer(vault, balance); deployedAssets = 0; }
    }

    // --- Admin ---
    function setRehedgeThresholdBps(uint256 bps) external onlyOwner { require(bps >= 100 && bps <= 1000); rehedgeThresholdBps = bps; }
    function setExpiryDuration(uint256 d) external onlyOwner { require(d >= 1 days && d <= 90 days); expiryDuration = d; }
    function setUnderlyingAsset(address a) external onlyOwner { underlyingAsset = a; }
    function setHedgeAssetId(uint32 id) external onlyOwner { hedgeAssetId = id; }
    function setCiaoSubAccountId(uint256 id) external onlyOwner { ciaoSubAccountId = id; }

    function _getSpotPrice() internal view returns (uint256) {
        (bool ok, bytes memory data) = address(0x0803).staticcall(abi.encodePacked(hedgeAssetId));
        if (ok && data.length >= 32) return abi.decode(data, (uint256));
        revert("Oracle unavailable");
    }
}
