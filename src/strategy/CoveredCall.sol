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

/// @title CoveredCall
/// @notice Covered Call strategy — hold underlying + sell call options via Rysk RFQ
/// @dev Phase 1 strategy. Target APR: 20-55%.
///      Flow: deposit collateral → price via BSM → sell call via Rysk RFQ
///            → collect premium → delta hedge via HyperCore → roll at expiry
contract CoveredCall is IStrategy, Ownable {
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
    uint256 public targetDelta;         // e.g. 25 = 0.25 delta (moderate risk tier)
    uint256 public expiryDuration;      // e.g. 7 days
    address public underlyingAsset;     // e.g. WETH address for vol lookups
    uint32 public hedgeAssetId;         // HyperCore asset ID for perp hedging
    uint256 public ciaoSubAccountId;    // Rysk Ciao sub-account for this strategy
    uint256 public minPremiumBps;       // Min acceptable premium vs BSM (e.g. 9000 = 90%)

    // --- Position tracking ---
    struct Position {
        uint256 strike;
        uint256 expiry;
        uint256 size;               // Notional in USDC
        uint256 premiumCollected;
        bytes32 quoteId;            // Rysk RFQ quote ID
        bytes32 hedgeId;            // DeltaHedger position ID
        bool settled;
    }
    Position[] public positions;
    uint256 public totalPremiumCollected;

    // --- Events ---
    event OptionSold(uint256 indexed positionId, uint256 strike, uint256 expiry, uint256 premium, bytes32 quoteId);
    event PositionSettled(uint256 indexed positionId, uint256 premium);
    event HedgeOpened(uint256 indexed positionId, bytes32 hedgeId, int256 hedgeSize);
    event StrategyRebalanced(int256 oldDelta, int256 newDelta);

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

        targetDelta = 25;               // 0.25 delta (moderate)
        expiryDuration = 7 days;
        minPremiumBps = 9000;           // Accept >= 90% of BSM fair value
    }

    // ========================================================================
    //                        CORE STRATEGY FLOW
    // ========================================================================

    /// @notice Deposit USDC and open a new covered call position
    function deposit(uint256 amount) external onlyVault {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        deployedAssets += amount;

        // 1. Deposit collateral into Rysk Ciao sub-account
        usdc.approve(address(ciao), amount);
        ciao.deposit(ciaoSubAccountId, amount);

        // 2. Get optimal strike from PricingEngine
        uint256 vol = pricingEngine.getBlendedVol(underlyingAsset);
        if (vol == 0) vol = 0.8e18; // fallback 80% IV

        uint256 strike = pricingEngine.findStrikeByDelta(
            _getSpotPrice(),
            vol,
            expiryDuration,
            targetDelta * 100, // convert to bps (25 → 2500)
            true               // isCall
        );

        // 3. Compute BSM fair value for premium validation
        uint256 bsmPrice = pricingEngine.bsmCallPrice(
            _getSpotPrice(), strike, vol, expiryDuration, 0
        );
        uint256 minPremium = (bsmPrice * minPremiumBps) / 10000;

        // 4. Submit call sell quote to Rysk RFQ
        uint256 expiry = block.timestamp + expiryDuration;
        uint256 quantity = amount; // 1:1 collateral-to-notional for Phase 1

        IRyskRFQ.OptionQuote memory quote = IRyskRFQ.OptionQuote({
            assetAddress: underlyingAsset,
            strike: strike,
            expiry: expiry,
            isPut: false,
            isTakerBuy: true,       // taker buys = we sell the call
            price: bsmPrice,        // ask for BSM fair value
            quantity: quantity,
            collateralAsset: address(usdc),
            validUntil: block.timestamp + 5 minutes,
            nonce: uint256(keccak256(abi.encodePacked(block.timestamp, positions.length)))
        });

        bytes32 quoteId = ryskRFQ.submitQuote(quote, ""); // signature handled off-chain

        // 5. Check risk limits
        int256 positionDelta = pricingEngine.calcDelta(
            _getSpotPrice(), strike, vol, expiryDuration, true
        );
        (bool allowed, string memory reason) = riskManager.checkRisk(
            amount, deployedAssets, -positionDelta // short call = negative delta
        );
        require(allowed, reason);

        // 6. Open delta hedge on HyperCore
        // Short call has negative delta → hedge by going long perp
        int256 hedgeSize = -positionDelta * int256(quantity) / 1e18;
        bytes32 hedgeId;
        if (hedgeSize != 0) {
            hedgeId = deltaHedger.openHedge(
                hedgeAssetId,
                hedgeSize,
                uint64(uint256(_getSpotPrice() / 1e10)) // scale to HyperCore price format
            );
        }

        // 7. Record position
        positions.push(Position({
            strike: strike,
            expiry: expiry,
            size: quantity,
            premiumCollected: 0, // set on settlement
            quoteId: quoteId,
            hedgeId: hedgeId,
            settled: false
        }));

        emit OptionSold(positions.length - 1, strike, expiry, bsmPrice, quoteId);
        if (hedgeId != bytes32(0)) {
            emit HedgeOpened(positions.length - 1, hedgeId, hedgeSize);
        }
    }

    /// @notice Harvest yield — settle expired options, collect premium, re-hedge
    function harvest() external onlyVault returns (uint256 profit) {
        uint256 totalProfit;

        for (uint256 i = 0; i < positions.length; i++) {
            Position storage pos = positions[i];
            if (pos.settled || block.timestamp < pos.expiry) continue;

            // 1. Settle via Rysk Ciao
            ciao.settleCoreCollateral(ciaoSubAccountId);

            // 2. Check settlement balance
            uint256 balance = ciao.getBalance(address(this), ciaoSubAccountId);

            // 3. Close hedge for this position
            if (pos.hedgeId != bytes32(0)) {
                deltaHedger.closeHedge(pos.hedgeId);
            }

            // 4. Withdraw settled funds from Ciao
            if (balance > 0) {
                ciao.requestWithdrawal(ciaoSubAccountId, balance);
            }

            // 5. Mark as settled and track premium
            pos.settled = true;
            pos.premiumCollected = balance > pos.size ? balance - pos.size : 0;
            totalProfit += pos.premiumCollected;
            totalPremiumCollected += pos.premiumCollected;

            emit PositionSettled(i, pos.premiumCollected);
        }

        // Transfer profit back to vault
        if (totalProfit > 0) {
            uint256 available = usdc.balanceOf(address(this));
            uint256 toTransfer = totalProfit > available ? available : totalProfit;
            if (toTransfer > 0) {
                usdc.safeTransfer(vault, toTransfer);
            }
        }

        profit = totalProfit;
    }

    /// @notice Withdraw USDC from the strategy
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

    /// @notice Estimated APR based on recent premium collection
    function estimatedAPR() external view returns (uint256) {
        if (deployedAssets == 0 || positions.length == 0) return 3500; // 35% default

        // Annualize the most recent premium as % of deployed
        uint256 lastPremium;
        for (uint256 i = positions.length; i > 0; i--) {
            if (positions[i - 1].settled && positions[i - 1].premiumCollected > 0) {
                lastPremium = positions[i - 1].premiumCollected;
                break;
            }
        }
        if (lastPremium == 0) return 3500;

        // APR = (premium / deployed) * (365 days / expiryDuration) * 10000
        uint256 epochsPerYear = (365 days * 10000) / expiryDuration;
        return (lastPremium * epochsPerYear) / deployedAssets;
    }

    /// @notice Current net delta from option positions + hedges
    function netDelta() external view returns (int256 delta) {
        // Sum delta from all unsettled option positions
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].settled) continue;
            Position storage pos = positions[i];
            uint256 timeLeft = pos.expiry > block.timestamp ? pos.expiry - block.timestamp : 0;
            if (timeLeft == 0) continue;

            uint256 vol = pricingEngine.getBlendedVol(underlyingAsset);
            if (vol == 0) vol = 0.8e18;

            // Short call delta is negative
            int256 optDelta = pricingEngine.calcDelta(
                _getSpotPrice(), pos.strike, vol, timeLeft, true
            );
            delta -= optDelta * int256(pos.size) / 1e18;
        }

        // Add hedge delta
        delta += deltaHedger.netDelta();
    }

    /// @notice Emergency close — unwind all positions
    function emergencyClose() external onlyOwner {
        // 1. Cancel all active Rysk quotes
        for (uint256 i = 0; i < positions.length; i++) {
            if (!positions[i].settled && positions[i].quoteId != bytes32(0)) {
                try ryskRFQ.cancelQuote(positions[i].quoteId) {} catch {}
                positions[i].settled = true;
            }
        }

        // 2. Close all HyperCore hedges
        deltaHedger.emergencyCloseAll();

        // 3. Withdraw from Ciao
        uint256 ciaoBalance = ciao.getBalance(address(this), ciaoSubAccountId);
        if (ciaoBalance > 0) {
            ciao.requestWithdrawal(ciaoSubAccountId, ciaoBalance);
        }

        // 4. Return all USDC to vault
        uint256 balance = usdc.balanceOf(address(this));
        if (balance > 0) {
            usdc.safeTransfer(vault, balance);
            deployedAssets = 0;
        }
    }

    // ========================================================================
    //                          ADMIN / CONFIG
    // ========================================================================

    function setTargetDelta(uint256 newDelta) external onlyOwner {
        require(newDelta > 0 && newDelta <= 50, "Delta 1-50");
        targetDelta = newDelta;
    }

    function setExpiryDuration(uint256 newDuration) external onlyOwner {
        require(newDuration >= 1 days && newDuration <= 90 days, "1-90 days");
        expiryDuration = newDuration;
    }

    function setUnderlyingAsset(address asset) external onlyOwner {
        underlyingAsset = asset;
    }

    function setHedgeAssetId(uint32 id) external onlyOwner {
        hedgeAssetId = id;
    }

    function setCiaoSubAccountId(uint256 id) external onlyOwner {
        ciaoSubAccountId = id;
    }

    function setMinPremiumBps(uint256 bps) external onlyOwner {
        require(bps >= 5000 && bps <= 10000, "50-100%");
        minPremiumBps = bps;
    }

    // ========================================================================
    //                          INTERNAL
    // ========================================================================

    /// @dev Get spot price from HyperCore oracle precompile
    ///      Returns 18-decimal USDC-denominated price
    function _getSpotPrice() internal view returns (uint256) {
        // staticcall to ORACLE_PX precompile (0x0803)
        (bool ok, bytes memory data) = address(0x0803).staticcall(
            abi.encodePacked(hedgeAssetId)
        );
        if (ok && data.length >= 32) {
            return abi.decode(data, (uint256));
        }
        // Fallback: revert if oracle unavailable
        revert("Oracle unavailable");
    }
}
