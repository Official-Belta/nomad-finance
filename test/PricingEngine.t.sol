// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PricingEngine} from "../src/pricing/PricingEngine.sol";
import {FixedPointMath} from "../src/libraries/FixedPointMath.sol";

contract PricingEngineTest is Test {
    PricingEngine public engine;

    int256 constant ONE = 1e18;

    // Test parameters: ETH ≈ $3000, 7-day expiry, 80% IV
    uint256 constant SPOT = 3000e18;
    uint256 constant VOL = 0.8e18;     // 80% annualized IV
    uint256 constant EXPIRY_7D = 7 days;
    uint256 constant RATE = 0;         // r=0 for crypto

    function setUp() public {
        engine = new PricingEngine(address(this));
    }

    // ========================================================================
    //                     FIXED POINT MATH TESTS
    // ========================================================================

    function test_sqrt() public pure {
        // sqrt(1) = 1
        assertApproxEqRel(FixedPointMath.sqrt(ONE), ONE, 0.001e18);

        // sqrt(4) = 2
        assertApproxEqRel(FixedPointMath.sqrt(4e18), 2e18, 0.001e18);

        // sqrt(0.25) = 0.5
        assertApproxEqRel(FixedPointMath.sqrt(0.25e18), 0.5e18, 0.01e18);
    }

    function test_ln() public pure {
        // ln(1) = 0
        assertEq(FixedPointMath.ln(ONE), 0);

        // ln(e) ≈ 1
        int256 e = 2_718_281_828_459_045_235; // e * 1e18
        assertApproxEqRel(FixedPointMath.ln(e), ONE, 0.01e18);

        // ln(2) ≈ 0.693
        assertApproxEqRel(FixedPointMath.ln(2e18), 693_147_180_559_945_309, 0.01e18);
    }

    function test_exp() public pure {
        // e^0 = 1
        assertEq(FixedPointMath.exp(0), ONE);

        // e^1 ≈ 2.718
        assertApproxEqRel(FixedPointMath.exp(ONE), 2_718_281_828_459_045_235, 0.01e18);

        // e^(-1) ≈ 0.368
        assertApproxEqRel(FixedPointMath.exp(-ONE), 367_879_441_171_442_321, 0.01e18);
    }

    function test_normalCdf() public pure {
        // N(0) = 0.5
        assertApproxEqRel(FixedPointMath.normalCdf(0), 0.5e18, 0.001e18);

        // N(large positive) ≈ 1
        int256 nHigh = FixedPointMath.normalCdf(5e18);
        assertGt(nHigh, 0.999e18);

        // N(large negative) ≈ 0
        int256 nLow = FixedPointMath.normalCdf(-5e18);
        assertLt(nLow, 0.001e18);

        // Symmetry: N(x) + N(-x) = 1
        int256 x = 1e18;
        int256 nx = FixedPointMath.normalCdf(x);
        int256 nNegX = FixedPointMath.normalCdf(-x);
        assertApproxEqAbs(nx + nNegX, ONE, 1e15); // within 0.001
    }

    function test_normalPdf() public pure {
        // n(0) = 1/sqrt(2π) ≈ 0.3989
        int256 pdf0 = FixedPointMath.normalPdf(0);
        assertApproxEqRel(pdf0, 398_942_280_401_432_677, 0.01e18);

        // PDF is symmetric: n(x) = n(-x)
        assertEq(FixedPointMath.normalPdf(1e18), FixedPointMath.normalPdf(-1e18));
    }

    // ========================================================================
    //                       BSM PRICING TESTS
    // ========================================================================

    function test_bsmCallPrice_ATM() public view {
        // ATM call: strike = spot. Should be > 0.
        uint256 price = engine.bsmCallPrice(SPOT, SPOT, VOL, EXPIRY_7D, RATE);
        assertGt(price, 0, "ATM call should have positive value");

        // ATM call price should be roughly S * σ * sqrt(T) * 0.4
        // For ETH $3000, 80% IV, 7 days: ≈ $3000 * 0.8 * sqrt(7/365.25) * 0.4 ≈ $133
        assertGt(price, 50e18, "Call too cheap");
        assertLt(price, 500e18, "Call too expensive");
    }

    function test_bsmPutPrice_ATM() public view {
        // ATM put = ATM call when r=0 (put-call parity)
        uint256 callPrice = engine.bsmCallPrice(SPOT, SPOT, VOL, EXPIRY_7D, RATE);
        uint256 putPrice = engine.bsmPutPrice(SPOT, SPOT, VOL, EXPIRY_7D, RATE);
        assertApproxEqRel(callPrice, putPrice, 0.05e18); // within 5% for ATM
    }

    function test_bsmCallPrice_deepOTM() public view {
        // Deep OTM call (strike = 2x spot) should be near zero
        uint256 price = engine.bsmCallPrice(SPOT, SPOT * 2, VOL, EXPIRY_7D, RATE);
        assertLt(price, 10e18, "Deep OTM call should be cheap");
    }

    function test_bsmCallPrice_deepITM() public view {
        // Deep ITM call (strike = spot / 2) should be ≈ intrinsic
        uint256 strike = SPOT / 2;
        uint256 price = engine.bsmCallPrice(SPOT, strike, VOL, EXPIRY_7D, RATE);
        uint256 intrinsic = SPOT - strike;
        assertGe(price, intrinsic * 99 / 100, "ITM call should be >= intrinsic");
    }

    function test_putCallParity() public view {
        // C - P = S - K * e^(-rT), with r=0: C - P = S - K
        uint256 strike = 3200e18; // OTM call
        uint256 callPrice = engine.bsmCallPrice(SPOT, strike, VOL, EXPIRY_7D, RATE);
        uint256 putPrice = engine.bsmPutPrice(SPOT, strike, VOL, EXPIRY_7D, RATE);

        // S - K = 3000 - 3200 = -200, so P > C by ~200
        if (strike > SPOT) {
            uint256 diff = strike - SPOT;
            assertApproxEqRel(putPrice - callPrice, diff, 0.05e18);
        }
    }

    // ========================================================================
    //                         GREEKS TESTS
    // ========================================================================

    function test_delta_call_ATM() public view {
        // ATM call delta ≈ 0.5
        int256 delta = engine.calcDelta(SPOT, SPOT, VOL, EXPIRY_7D, true);
        assertApproxEqRel(delta, 0.5e18, 0.1e18); // within 10%
    }

    function test_delta_put_ATM() public view {
        // ATM put delta ≈ -0.5
        int256 delta = engine.calcDelta(SPOT, SPOT, VOL, EXPIRY_7D, false);
        assertApproxEqRel(delta, -0.5e18, 0.1e18);
    }

    function test_delta_callPut_relationship() public view {
        // delta_call - delta_put = 1
        uint256 strike = 3100e18;
        int256 callDelta = engine.calcDelta(SPOT, strike, VOL, EXPIRY_7D, true);
        int256 putDelta = engine.calcDelta(SPOT, strike, VOL, EXPIRY_7D, false);
        assertApproxEqAbs(callDelta - putDelta, ONE, 1e15);
    }

    function test_gamma_ATM() public view {
        // ATM gamma should be highest
        uint256 gammaATM = engine.calcGamma(SPOT, SPOT, VOL, EXPIRY_7D);
        uint256 gammaOTM = engine.calcGamma(SPOT, SPOT * 12 / 10, VOL, EXPIRY_7D);
        assertGt(gammaATM, gammaOTM, "ATM gamma should be > OTM gamma");
    }

    function test_vega_positive() public view {
        uint256 vega = engine.calcVega(SPOT, SPOT, VOL, EXPIRY_7D);
        assertGt(vega, 0, "Vega should be positive");
    }

    function test_theta_negative() public view {
        // Theta should be negative (time decay)
        int256 theta = engine.calcTheta(SPOT, SPOT, VOL, EXPIRY_7D, true);
        assertLt(theta, 0, "Theta should be negative");
    }

    // ========================================================================
    //                     STRIKE SELECTION TESTS
    // ========================================================================

    function test_findStrike_call_25delta() public view {
        // Find 0.25 delta call strike (should be above spot)
        uint256 strike = engine.findStrikeByDelta(SPOT, VOL, EXPIRY_7D, 2500, true);
        assertGt(strike, SPOT, "0.25d call strike should be OTM (above spot)");

        // Verify the found strike actually produces ~0.25 delta
        int256 delta = engine.calcDelta(SPOT, strike, VOL, EXPIRY_7D, true);
        assertApproxEqRel(delta, 0.25e18, 0.15e18); // within 15%
    }

    function test_findStrike_put_25delta() public view {
        // Find 0.25 |delta| put strike (should be below spot)
        uint256 strike = engine.findStrikeByDelta(SPOT, VOL, EXPIRY_7D, 2500, false);
        assertLt(strike, SPOT, "0.25d put strike should be OTM (below spot)");

        // Verify
        int256 delta = engine.calcDelta(SPOT, strike, VOL, EXPIRY_7D, false);
        assertApproxEqRel(-delta, 0.25e18, 0.15e18);
    }

    function test_findStrike_higherDelta_closerToATM() public view {
        uint256 strike25 = engine.findStrikeByDelta(SPOT, VOL, EXPIRY_7D, 2500, true);
        uint256 strike15 = engine.findStrikeByDelta(SPOT, VOL, EXPIRY_7D, 1500, true);

        // Higher delta = closer to ATM = lower strike for calls
        assertLt(strike25, strike15, "Higher delta call should have lower strike");
    }

    // ========================================================================
    //                     EWMA VOLATILITY TESTS
    // ========================================================================

    function test_initAndUpdateVol() public {
        address asset = address(0x1);
        bytes32 window = keccak256("1d");

        engine.initVolWindow(asset, window, 0.8e18, 0.94e18);
        (uint256 vol,,) = engine.volData(asset, window);
        assertEq(vol, 0.8e18);

        // Update with a squared return
        engine.updateVol(asset, window, 0.01e18); // 1% squared return
        (uint256 newVol,,) = engine.volData(asset, window);
        assertGt(newVol, 0, "Vol should be positive after update");
    }

    function test_blendedVol() public {
        address asset = address(0x1);

        engine.initVolWindow(asset, keccak256("4h"), 0.7e18, 0.94e18);
        engine.initVolWindow(asset, keccak256("1d"), 0.8e18, 0.94e18);
        engine.initVolWindow(asset, keccak256("7d"), 0.9e18, 0.94e18);
        engine.initVolWindow(asset, keccak256("30d"), 1.0e18, 0.94e18);

        uint256 blended = engine.getBlendedVol(asset);
        // Expected: 0.7*20 + 0.8*40 + 0.9*30 + 1.0*10 = 14+32+27+10 = 83 / 100 = 0.83
        assertApproxEqRel(blended, 0.83e18, 0.01e18);
    }
}
