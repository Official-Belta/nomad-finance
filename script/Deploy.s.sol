// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NomadVault} from "../src/vault/NomadVault.sol";
import {NomadAutoVault} from "../src/vault/NomadAutoVault.sol";
import {StrategyAllocator} from "../src/vault/StrategyAllocator.sol";
import {PricingEngine} from "../src/pricing/PricingEngine.sol";
import {DeltaHedger} from "../src/hedge/DeltaHedger.sol";
import {RiskManager} from "../src/risk/RiskManager.sol";
import {CoveredCall} from "../src/strategy/CoveredCall.sol";
import {CashSecuredPut} from "../src/strategy/CashSecuredPut.sol";
import {IronCondor} from "../src/strategy/IronCondor.sol";
import {BullCallSpread} from "../src/strategy/BullCallSpread.sol";
import {Straddle} from "../src/strategy/Straddle.sol";

/// @title Deploy
/// @notice Full Nomad Protocol deployment (Phase 1 + Phase 2)
contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address owner = vm.envAddress("OWNER_ADDRESS");
        address ryskRFQ = vm.envAddress("RYSK_RFQ_ADDRESS");
        address ciao = vm.envAddress("CIAO_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        // --- Core Infrastructure ---
        PricingEngine pricingEngine = new PricingEngine(owner);
        DeltaHedger deltaHedger = new DeltaHedger(owner);
        RiskManager riskManager = new RiskManager(owner);
        StrategyAllocator allocator = new StrategyAllocator(owner);

        // --- Phase 1: Single Strategy Vault ---
        NomadVault vault = new NomadVault(
            IERC20(usdc), "Nomad Vault", "nVAULT", owner,
            7 days, 1_000_000e18
        );

        // --- Phase 1 Strategies ---
        CoveredCall cc = new CoveredCall(
            usdc, address(vault), owner,
            ryskRFQ, ciao,
            address(pricingEngine), address(deltaHedger), address(riskManager)
        );

        CashSecuredPut csp = new CashSecuredPut(
            usdc, address(vault), owner,
            ryskRFQ, ciao,
            address(pricingEngine), address(deltaHedger), address(riskManager)
        );

        // --- Phase 2: Multi-Strategy Vault ---
        NomadAutoVault autoVault = new NomadAutoVault(
            IERC20(usdc), "Nomad Auto Vault", "naVAULT", owner,
            address(allocator), address(riskManager),
            7 days, 5_000_000e18
        );

        // --- Phase 2 Strategies ---
        IronCondor ic = new IronCondor(
            usdc, address(autoVault), owner,
            ryskRFQ, ciao,
            address(pricingEngine), address(deltaHedger), address(riskManager)
        );

        BullCallSpread bcs = new BullCallSpread(
            usdc, address(autoVault), owner,
            ryskRFQ, ciao,
            address(pricingEngine), address(deltaHedger), address(riskManager)
        );

        Straddle straddle = new Straddle(
            usdc, address(autoVault), owner,
            ryskRFQ, ciao,
            address(pricingEngine), address(deltaHedger), address(riskManager)
        );

        // --- Register strategies in allocator ---
        allocator.addStrategy(address(cc), "CoveredCall");
        allocator.addStrategy(address(csp), "CashSecuredPut");
        allocator.addStrategy(address(ic), "IronCondor");
        allocator.addStrategy(address(bcs), "BullCallSpread");
        allocator.addStrategy(address(straddle), "Straddle");

        // --- Set risk profiles ---
        uint256[] memory conservative = new uint256[](5);
        conservative[0] = 7000;  // 70% CC
        conservative[1] = 2000;  // 20% CSP
        conservative[2] = 1000;  // 10% IC
        allocator.setRiskProfile(0, "Conservative", conservative);

        uint256[] memory moderate = new uint256[](5);
        moderate[0] = 4000;  // 40% CC
        moderate[1] = 2000;  // 20% CSP
        moderate[2] = 2500;  // 25% IC
        moderate[3] = 1000;  // 10% BCS
        moderate[4] = 500;   //  5% Straddle
        allocator.setRiskProfile(1, "Moderate", moderate);

        uint256[] memory aggressive = new uint256[](5);
        aggressive[0] = 3000;  // 30% CC
        aggressive[1] = 1000;  // 10% CSP
        aggressive[2] = 3000;  // 30% IC
        aggressive[3] = 2000;  // 20% BCS
        aggressive[4] = 1000;  // 10% Straddle
        allocator.setRiskProfile(2, "Aggressive", aggressive);

        allocator.setActiveRiskTier(1); // Default: Moderate

        vm.stopBroadcast();

        // --- Log addresses ---
        console2.log("=== Nomad Protocol Deployed ===");
        console2.log("PricingEngine:", address(pricingEngine));
        console2.log("DeltaHedger:", address(deltaHedger));
        console2.log("RiskManager:", address(riskManager));
        console2.log("StrategyAllocator:", address(allocator));
        console2.log("NomadVault (Phase 1):", address(vault));
        console2.log("NomadAutoVault (Phase 2):", address(autoVault));
        console2.log("CoveredCall:", address(cc));
        console2.log("CashSecuredPut:", address(csp));
        console2.log("IronCondor:", address(ic));
        console2.log("BullCallSpread:", address(bcs));
        console2.log("Straddle:", address(straddle));
    }
}
