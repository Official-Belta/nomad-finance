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

/// @title ProtectivePut
/// @notice Protective Put strategy — buy OTM put as downside insurance
/// @dev Phase 2 strategy. Used as portfolio hedge, not standalone yield.
///      Flow: buy put option → if underlying drops below strike, profit offsets losses
///      Cost = premium paid. This is a net debit strategy (costs money).
///      Typically paired with CC/CSP vaults to protect TVL during crashes.
contract ProtectivePut is IStrategy, Ownable {
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

    uint256 public putDelta;         // e.g. 30 = 0.30 |delta| (moderate protection)

    struct PutPosition {
        uint256 strike;
        uint256 expiry;
        uint256 size;
        uint256 premiumPaid;
        bytes32 quoteId;
        bool settled;
        uint256 payout;              // Settlement payout if ITM
    }
    PutPosition[] public positions;

    event PutBought(uint256 indexed id, uint256 strike, uint256 expiry, uint256 premium);
    event PutSettled(uint256 indexed id, uint256 payout);

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

        expiryDuration = 30 days;   // longer duration for insurance
        putDelta = 30;
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

        // Find OTM put strike
        uint256 strike = pricingEngine.findStrikeByDelta(
            spot, vol, expiryDuration, putDelta * 100, false
        );

        uint256 premium = pricingEngine.bsmPutPrice(spot, strike, vol, expiryDuration, 0);

        // Buy the put (we are buyer)
        bytes32 quoteId = ryskRFQ.submitQuote(
            IRyskRFQ.OptionQuote({
                assetAddress: underlyingAsset,
                strike: strike,
                expiry: expiry,
                isPut: true,
                isTakerBuy: false,   // we buy the put
                price: premium,
                quantity: amount,
                collateralAsset: address(usdc),
                validUntil: block.timestamp + 5 minutes,
                nonce: uint256(keccak256(abi.encodePacked(block.timestamp, strike)))
            }),
            ""
        );

        positions.push(PutPosition({
            strike: strike,
            expiry: expiry,
            size: amount,
            premiumPaid: premium,
            quoteId: quoteId,
            settled: false,
            payout: 0
        }));

        emit PutBought(positions.length - 1, strike, expiry, premium);
    }

    function harvest() external onlyVault returns (uint256 profit) {
        uint256 totalPayout;
        for (uint256 i = 0; i < positions.length; i++) {
            PutPosition storage pos = positions[i];
            if (pos.settled || block.timestamp < pos.expiry) continue;

            ciao.settleCoreCollateral(ciaoSubAccountId);
            uint256 balance = ciao.getBalance(address(this), ciaoSubAccountId);
            if (balance > 0) ciao.requestWithdrawal(ciaoSubAccountId, balance);

            pos.settled = true;
            // Profit = payout - premium paid (can be negative, but we return 0 minimum)
            pos.payout = balance > pos.size ? balance - pos.size : 0;
            if (pos.payout > pos.premiumPaid) {
                totalPayout += pos.payout - pos.premiumPaid;
            }

            emit PutSettled(i, pos.payout);
        }

        if (totalPayout > 0) {
            uint256 available = usdc.balanceOf(address(this));
            uint256 toTransfer = totalPayout > available ? available : totalPayout;
            if (toTransfer > 0) usdc.safeTransfer(vault, toTransfer);
        }
        profit = totalPayout;
    }

    function withdraw(uint256 amount) external onlyVault returns (uint256) {
        uint256 available = usdc.balanceOf(address(this));
        uint256 toWithdraw = amount > available ? available : amount;
        deployedAssets = deployedAssets > toWithdraw ? deployedAssets - toWithdraw : 0;
        usdc.safeTransfer(vault, toWithdraw);
        return toWithdraw;
    }

    function totalDeployedAssets() external view returns (uint256) { return deployedAssets; }

    /// @notice Negative APR expected — this is insurance, not yield
    function estimatedAPR() external pure returns (uint256) {
        return 0; // Insurance strategy: no positive yield expected
    }

    function netDelta() external view returns (int256 delta) {
        uint256 vol = pricingEngine.getBlendedVol(underlyingAsset);
        if (vol == 0) vol = 0.8e18;
        uint256 spot = _getSpotPrice();

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].settled) continue;
            PutPosition storage pos = positions[i];
            uint256 timeLeft = pos.expiry > block.timestamp ? pos.expiry - block.timestamp : 0;
            if (timeLeft == 0) continue;

            // Long put = negative delta
            int256 d = pricingEngine.calcDelta(spot, pos.strike, vol, timeLeft, false);
            delta += d * int256(pos.size) / 1e18;
        }
    }

    function emergencyClose() external onlyOwner {
        for (uint256 i = 0; i < positions.length; i++) {
            if (!positions[i].settled && positions[i].quoteId != bytes32(0)) {
                try ryskRFQ.cancelQuote(positions[i].quoteId) {} catch {}
                positions[i].settled = true;
            }
        }
        uint256 ciaoBalance = ciao.getBalance(address(this), ciaoSubAccountId);
        if (ciaoBalance > 0) ciao.requestWithdrawal(ciaoSubAccountId, ciaoBalance);
        uint256 balance = usdc.balanceOf(address(this));
        if (balance > 0) { usdc.safeTransfer(vault, balance); deployedAssets = 0; }
    }

    // --- Admin ---
    function setPutDelta(uint256 d) external onlyOwner { require(d >= 10 && d <= 50); putDelta = d; }
    function setExpiryDuration(uint256 d) external onlyOwner { require(d >= 7 days && d <= 180 days); expiryDuration = d; }
    function setUnderlyingAsset(address a) external onlyOwner { underlyingAsset = a; }
    function setHedgeAssetId(uint32 id) external onlyOwner { hedgeAssetId = id; }
    function setCiaoSubAccountId(uint256 id) external onlyOwner { ciaoSubAccountId = id; }

    function _getSpotPrice() internal view returns (uint256) {
        (bool ok, bytes memory data) = address(0x0803).staticcall(abi.encodePacked(hedgeAssetId));
        if (ok && data.length >= 32) return abi.decode(data, (uint256));
        revert("Oracle unavailable");
    }
}
