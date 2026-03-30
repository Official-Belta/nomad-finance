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

/// @title IronCondor
/// @notice Iron Condor strategy — sell OTM call + sell OTM put (range-bound premium)
/// @dev Phase 2 strategy. Profits when underlying stays within a range.
///      Structure: short call spread + short put spread
///      - Sell OTM call at upper strike, buy further OTM call (cap loss)
///      - Sell OTM put at lower strike, buy further OTM put (cap loss)
///      Max profit = net premium collected. Max loss = spread width - premium.
contract IronCondor is IStrategy, Ownable {
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

    // Iron Condor parameters
    uint256 public shortCallDelta;   // e.g. 20 = 0.20 delta for short call
    uint256 public shortPutDelta;    // e.g. 20 = 0.20 |delta| for short put
    uint256 public spreadWidthBps;   // Width of each spread in bps of spot (e.g. 500 = 5%)

    struct CondorPosition {
        uint256 shortCallStrike;
        uint256 longCallStrike;
        uint256 shortPutStrike;
        uint256 longPutStrike;
        uint256 expiry;
        uint256 size;
        uint256 premiumCollected;
        bytes32[4] quoteIds;     // [shortCall, longCall, shortPut, longPut]
        bytes32 hedgeId;
        bool settled;
    }
    CondorPosition[] public positions;
    uint256 public totalPremiumCollected;

    event CondorOpened(uint256 indexed id, uint256 shortCallStrike, uint256 shortPutStrike, uint256 premium);
    event CondorSettled(uint256 indexed id, uint256 premium);

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
        shortCallDelta = 20;
        shortPutDelta = 20;
        spreadWidthBps = 500; // 5% spread width
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

        // Find short strikes by delta
        uint256 shortCallStrike = pricingEngine.findStrikeByDelta(
            spot, vol, expiryDuration, shortCallDelta * 100, true
        );
        uint256 shortPutStrike = pricingEngine.findStrikeByDelta(
            spot, vol, expiryDuration, shortPutDelta * 100, false
        );

        // Long strikes = short ± spread width
        uint256 spreadWidth = (spot * spreadWidthBps) / 10000;
        uint256 longCallStrike = shortCallStrike + spreadWidth;
        uint256 longPutStrike = shortPutStrike > spreadWidth ? shortPutStrike - spreadWidth : 1;

        // Half the capital per leg
        uint256 legSize = amount / 2;

        // Submit 4 quotes: sell short call, buy long call, sell short put, buy long put
        bytes32[4] memory quoteIds;
        quoteIds[0] = _submitQuote(shortCallStrike, expiry, false, true, legSize, vol, spot);   // sell call
        quoteIds[1] = _submitQuote(longCallStrike, expiry, false, false, legSize, vol, spot);    // buy call
        quoteIds[2] = _submitQuote(shortPutStrike, expiry, true, true, legSize, vol, spot);      // sell put
        quoteIds[3] = _submitQuote(longPutStrike, expiry, true, false, legSize, vol, spot);      // buy put

        // Net premium = short premiums - long premiums (positive for credit spread)
        uint256 shortCallPrem = pricingEngine.bsmCallPrice(spot, shortCallStrike, vol, expiryDuration, 0);
        uint256 longCallPrem = pricingEngine.bsmCallPrice(spot, longCallStrike, vol, expiryDuration, 0);
        uint256 shortPutPrem = pricingEngine.bsmPutPrice(spot, shortPutStrike, vol, expiryDuration, 0);
        uint256 longPutPrem = pricingEngine.bsmPutPrice(spot, longPutStrike, vol, expiryDuration, 0);
        uint256 netPremium = (shortCallPrem + shortPutPrem) - (longCallPrem + longPutPrem);

        // Risk check — iron condor is near delta-neutral
        int256 callDelta = pricingEngine.calcDelta(spot, shortCallStrike, vol, expiryDuration, true);
        int256 putDelta = pricingEngine.calcDelta(spot, shortPutStrike, vol, expiryDuration, false);
        int256 netPositionDelta = -(callDelta + putDelta) * int256(legSize) / 1e18;

        (bool allowed, string memory reason) = riskManager.checkRisk(amount, deployedAssets, netPositionDelta);
        require(allowed, reason);

        // Small hedge if residual delta exists
        bytes32 hedgeId;
        if (netPositionDelta != 0) {
            hedgeId = deltaHedger.openHedge(
                hedgeAssetId, -netPositionDelta,
                uint64(uint256(spot / 1e10))
            );
        }

        positions.push(CondorPosition({
            shortCallStrike: shortCallStrike,
            longCallStrike: longCallStrike,
            shortPutStrike: shortPutStrike,
            longPutStrike: longPutStrike,
            expiry: expiry,
            size: amount,
            premiumCollected: 0,
            quoteIds: quoteIds,
            hedgeId: hedgeId,
            settled: false
        }));

        emit CondorOpened(positions.length - 1, shortCallStrike, shortPutStrike, netPremium);
    }

    function harvest() external onlyVault returns (uint256 profit) {
        uint256 totalProfit;
        for (uint256 i = 0; i < positions.length; i++) {
            CondorPosition storage pos = positions[i];
            if (pos.settled || block.timestamp < pos.expiry) continue;

            ciao.settleCoreCollateral(ciaoSubAccountId);
            uint256 balance = ciao.getBalance(address(this), ciaoSubAccountId);

            if (pos.hedgeId != bytes32(0)) deltaHedger.closeHedge(pos.hedgeId);
            if (balance > 0) ciao.requestWithdrawal(ciaoSubAccountId, balance);

            pos.settled = true;
            pos.premiumCollected = balance > pos.size ? balance - pos.size : 0;
            totalProfit += pos.premiumCollected;
            totalPremiumCollected += pos.premiumCollected;

            emit CondorSettled(i, pos.premiumCollected);
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
        if (deployedAssets == 0 || positions.length == 0) return 2500;
        uint256 lastPremium;
        for (uint256 i = positions.length; i > 0; i--) {
            if (positions[i - 1].settled && positions[i - 1].premiumCollected > 0) {
                lastPremium = positions[i - 1].premiumCollected;
                break;
            }
        }
        if (lastPremium == 0) return 2500;
        return (lastPremium * (365 days * 10000) / expiryDuration) / deployedAssets;
    }

    function netDelta() external view returns (int256 delta) {
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].settled) continue;
            CondorPosition storage pos = positions[i];
            uint256 timeLeft = pos.expiry > block.timestamp ? pos.expiry - block.timestamp : 0;
            if (timeLeft == 0) continue;

            uint256 vol = pricingEngine.getBlendedVol(underlyingAsset);
            if (vol == 0) vol = 0.8e18;
            uint256 spot = _getSpotPrice();

            int256 cd = pricingEngine.calcDelta(spot, pos.shortCallStrike, vol, timeLeft, true);
            int256 pd = pricingEngine.calcDelta(spot, pos.shortPutStrike, vol, timeLeft, false);
            delta -= (cd + pd) * int256(pos.size / 2) / 1e18;
        }
        delta += deltaHedger.netDelta();
    }

    function emergencyClose() external onlyOwner {
        for (uint256 i = 0; i < positions.length; i++) {
            if (!positions[i].settled) {
                for (uint256 j = 0; j < 4; j++) {
                    if (positions[i].quoteIds[j] != bytes32(0)) {
                        try ryskRFQ.cancelQuote(positions[i].quoteIds[j]) {} catch {}
                    }
                }
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
    function setShortCallDelta(uint256 d) external onlyOwner { require(d > 0 && d <= 50); shortCallDelta = d; }
    function setShortPutDelta(uint256 d) external onlyOwner { require(d > 0 && d <= 50); shortPutDelta = d; }
    function setSpreadWidthBps(uint256 w) external onlyOwner { require(w >= 100 && w <= 2000); spreadWidthBps = w; }
    function setExpiryDuration(uint256 d) external onlyOwner { require(d >= 1 days && d <= 90 days); expiryDuration = d; }
    function setUnderlyingAsset(address a) external onlyOwner { underlyingAsset = a; }
    function setHedgeAssetId(uint32 id) external onlyOwner { hedgeAssetId = id; }
    function setCiaoSubAccountId(uint256 id) external onlyOwner { ciaoSubAccountId = id; }

    // --- Internal ---
    function _submitQuote(
        uint256 strike, uint256 expiry, bool isPut, bool isSell,
        uint256 quantity, uint256 vol, uint256 spot
    ) internal returns (bytes32) {
        uint256 price = isPut
            ? pricingEngine.bsmPutPrice(spot, strike, vol, expiryDuration, 0)
            : pricingEngine.bsmCallPrice(spot, strike, vol, expiryDuration, 0);

        return ryskRFQ.submitQuote(
            IRyskRFQ.OptionQuote({
                assetAddress: underlyingAsset,
                strike: strike,
                expiry: expiry,
                isPut: isPut,
                isTakerBuy: isSell,  // isTakerBuy=true means we sell
                price: price,
                quantity: quantity,
                collateralAsset: address(usdc),
                validUntil: block.timestamp + 5 minutes,
                nonce: uint256(keccak256(abi.encodePacked(block.timestamp, strike, isPut)))
            }),
            ""
        );
    }

    function _getSpotPrice() internal view returns (uint256) {
        (bool ok, bytes memory data) = address(0x0803).staticcall(abi.encodePacked(hedgeAssetId));
        if (ok && data.length >= 32) return abi.decode(data, (uint256));
        revert("Oracle unavailable");
    }
}
