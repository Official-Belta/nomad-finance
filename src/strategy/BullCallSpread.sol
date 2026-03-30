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

/// @title BullCallSpread
/// @notice Bull Call Spread — buy ATM/ITM call + sell OTM call (directional bullish)
/// @dev Phase 2 strategy. Net debit spread. Profits from moderate upward moves.
///      Max profit = spread width - net debit. Max loss = net debit paid.
contract BullCallSpread is IStrategy, Ownable {
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

    uint256 public longCallDelta;    // e.g. 55 = 0.55 delta (slightly ITM)
    uint256 public shortCallDelta;   // e.g. 25 = 0.25 delta (OTM)

    struct SpreadPosition {
        uint256 longStrike;
        uint256 shortStrike;
        uint256 expiry;
        uint256 size;
        uint256 netDebit;        // Premium paid - premium received
        bytes32 longQuoteId;
        bytes32 shortQuoteId;
        bytes32 hedgeId;
        bool settled;
        uint256 settlementProfit;
    }
    SpreadPosition[] public positions;

    event SpreadOpened(uint256 indexed id, uint256 longStrike, uint256 shortStrike, uint256 netDebit);
    event SpreadSettled(uint256 indexed id, uint256 profit);

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

        expiryDuration = 14 days;   // longer duration for directional
        longCallDelta = 55;
        shortCallDelta = 25;
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

        // Long call: higher delta (closer to ATM/ITM)
        uint256 longStrike = pricingEngine.findStrikeByDelta(
            spot, vol, expiryDuration, longCallDelta * 100, true
        );
        // Short call: lower delta (further OTM)
        uint256 shortStrike = pricingEngine.findStrikeByDelta(
            spot, vol, expiryDuration, shortCallDelta * 100, true
        );
        require(shortStrike > longStrike, "Invalid spread");

        uint256 longPrem = pricingEngine.bsmCallPrice(spot, longStrike, vol, expiryDuration, 0);
        uint256 shortPrem = pricingEngine.bsmCallPrice(spot, shortStrike, vol, expiryDuration, 0);
        uint256 netDebit = longPrem > shortPrem ? longPrem - shortPrem : 0;

        // Buy long call (we buy = isTakerBuy false, we are the maker buying)
        bytes32 longQuoteId = ryskRFQ.submitQuote(
            IRyskRFQ.OptionQuote({
                assetAddress: underlyingAsset,
                strike: longStrike,
                expiry: expiry,
                isPut: false,
                isTakerBuy: false,   // we buy
                price: longPrem,
                quantity: amount,
                collateralAsset: address(usdc),
                validUntil: block.timestamp + 5 minutes,
                nonce: uint256(keccak256(abi.encodePacked(block.timestamp, longStrike)))
            }),
            ""
        );

        // Sell short call
        bytes32 shortQuoteId = ryskRFQ.submitQuote(
            IRyskRFQ.OptionQuote({
                assetAddress: underlyingAsset,
                strike: shortStrike,
                expiry: expiry,
                isPut: false,
                isTakerBuy: true,    // we sell
                price: shortPrem,
                quantity: amount,
                collateralAsset: address(usdc),
                validUntil: block.timestamp + 5 minutes,
                nonce: uint256(keccak256(abi.encodePacked(block.timestamp, shortStrike)))
            }),
            ""
        );

        // Risk check — net long delta from spread
        int256 longDelta = pricingEngine.calcDelta(spot, longStrike, vol, expiryDuration, true);
        int256 shortDeltaVal = pricingEngine.calcDelta(spot, shortStrike, vol, expiryDuration, true);
        int256 netDelta_ = (longDelta - shortDeltaVal) * int256(amount) / 1e18;

        (bool allowed, string memory reason) = riskManager.checkRisk(amount, deployedAssets, netDelta_);
        require(allowed, reason);

        // Hedge residual delta
        bytes32 hedgeId;
        if (netDelta_ != 0) {
            hedgeId = deltaHedger.openHedge(hedgeAssetId, -netDelta_, uint64(uint256(spot / 1e10)));
        }

        positions.push(SpreadPosition({
            longStrike: longStrike,
            shortStrike: shortStrike,
            expiry: expiry,
            size: amount,
            netDebit: netDebit,
            longQuoteId: longQuoteId,
            shortQuoteId: shortQuoteId,
            hedgeId: hedgeId,
            settled: false,
            settlementProfit: 0
        }));

        emit SpreadOpened(positions.length - 1, longStrike, shortStrike, netDebit);
    }

    function harvest() external onlyVault returns (uint256 profit) {
        uint256 totalProfit;
        for (uint256 i = 0; i < positions.length; i++) {
            SpreadPosition storage pos = positions[i];
            if (pos.settled || block.timestamp < pos.expiry) continue;

            ciao.settleCoreCollateral(ciaoSubAccountId);
            uint256 balance = ciao.getBalance(address(this), ciaoSubAccountId);

            if (pos.hedgeId != bytes32(0)) deltaHedger.closeHedge(pos.hedgeId);
            if (balance > 0) ciao.requestWithdrawal(ciaoSubAccountId, balance);

            pos.settled = true;
            pos.settlementProfit = balance > pos.size ? balance - pos.size : 0;
            totalProfit += pos.settlementProfit;

            emit SpreadSettled(i, pos.settlementProfit);
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
        if (deployedAssets == 0 || positions.length == 0) return 2000;
        uint256 lastProfit;
        for (uint256 i = positions.length; i > 0; i--) {
            if (positions[i - 1].settled && positions[i - 1].settlementProfit > 0) {
                lastProfit = positions[i - 1].settlementProfit;
                break;
            }
        }
        if (lastProfit == 0) return 2000;
        return (lastProfit * (365 days * 10000) / expiryDuration) / deployedAssets;
    }

    function netDelta() external view returns (int256 delta) {
        uint256 vol = pricingEngine.getBlendedVol(underlyingAsset);
        if (vol == 0) vol = 0.8e18;
        uint256 spot = _getSpotPrice();

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].settled) continue;
            SpreadPosition storage pos = positions[i];
            uint256 timeLeft = pos.expiry > block.timestamp ? pos.expiry - block.timestamp : 0;
            if (timeLeft == 0) continue;

            int256 ld = pricingEngine.calcDelta(spot, pos.longStrike, vol, timeLeft, true);
            int256 sd = pricingEngine.calcDelta(spot, pos.shortStrike, vol, timeLeft, true);
            delta += (ld - sd) * int256(pos.size) / 1e18;
        }
        delta += deltaHedger.netDelta();
    }

    function emergencyClose() external onlyOwner {
        for (uint256 i = 0; i < positions.length; i++) {
            if (!positions[i].settled) {
                if (positions[i].longQuoteId != bytes32(0))
                    try ryskRFQ.cancelQuote(positions[i].longQuoteId) {} catch {}
                if (positions[i].shortQuoteId != bytes32(0))
                    try ryskRFQ.cancelQuote(positions[i].shortQuoteId) {} catch {}
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
    function setLongCallDelta(uint256 d) external onlyOwner { require(d >= 30 && d <= 70); longCallDelta = d; }
    function setShortCallDelta(uint256 d) external onlyOwner { require(d > 0 && d <= 50); shortCallDelta = d; }
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
