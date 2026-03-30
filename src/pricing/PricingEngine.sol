// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";

/// @title PricingEngine
/// @notice On-chain BSM pricing + EWMA vol + Greeks computation
/// @dev Ported from Python NomadPricingEngine prototype.
///      All prices/values use 18-decimal fixed-point unless noted.
///      Used for: strike selection, premium validation, risk assessment.
contract PricingEngine is Ownable {
    using FixedPointMath for int256;

    // --- Constants ---
    int256 constant ONE = 1e18;
    uint256 constant SECONDS_PER_YEAR = 365.25 days;

    // Risk tier target deltas (scaled by 100, e.g. 15 = 0.15)
    uint256 public constant CONSERVATIVE_DELTA = 15;
    uint256 public constant MODERATE_DELTA = 25;
    uint256 public constant AGGRESSIVE_DELTA = 35;

    // --- EWMA Volatility ---
    struct VolWindow {
        uint256 vol;        // EWMA vol (18 decimals) — annualized
        uint256 lastUpdate;
        uint256 lambda;     // Decay factor (18 decimals, e.g. 0.94e18)
    }

    // asset => window label => VolWindow
    mapping(address => mapping(bytes32 => VolWindow)) public volData;

    // Window labels
    bytes32 constant W_1H = keccak256("1h");
    bytes32 constant W_4H = keccak256("4h");
    bytes32 constant W_1D = keccak256("1d");
    bytes32 constant W_7D = keccak256("7d");
    bytes32 constant W_30D = keccak256("30d");

    event VolUpdated(address indexed asset, bytes32 window, uint256 newVol);
    event StrikeSelected(address indexed asset, uint256 strike, uint256 delta, uint256 riskTier);

    constructor(address owner_) Ownable(owner_) {}

    // ========================================================================
    //                          BSM PRICING
    // ========================================================================

    /// @notice Calculate BSM d1 and d2
    /// @param spot Current spot price (18 dec)
    /// @param strike Strike price (18 dec)
    /// @param vol Implied volatility (18 dec, e.g. 0.9e18 = 90%)
    /// @param timeToExpiry Time to expiry in seconds
    /// @param riskFreeRate Annual risk-free rate (18 dec, e.g. 0.05e18 = 5%)
    function _d1d2(
        int256 spot,
        int256 strike,
        int256 vol,
        int256 timeToExpiry,
        int256 riskFreeRate
    ) internal pure returns (int256 d1, int256 d2) {
        // T = timeToExpiry / SECONDS_PER_YEAR
        int256 T = (timeToExpiry * ONE) / int256(SECONDS_PER_YEAR);

        // sqrtT = sqrt(T)
        int256 sqrtT = FixedPointMath.sqrt(T);

        // volSqrtT = vol * sqrt(T)
        int256 volSqrtT = vol.mulDown(sqrtT);
        require(volSqrtT > 0, "volSqrtT zero");

        // d1 = (ln(S/K) + (r + vol^2/2) * T) / (vol * sqrt(T))
        int256 lnSK = FixedPointMath.ln(spot.divDown(strike));
        int256 volSqHalf = vol.mulDown(vol) / 2;
        int256 drift = (riskFreeRate + volSqHalf).mulDown(T);

        d1 = (lnSK + drift).divDown(volSqrtT);
        d2 = d1 - volSqrtT;
    }

    /// @notice Calculate BSM call price
    /// @return price Call option price (18 dec)
    function bsmCallPrice(
        uint256 spot,
        uint256 strike,
        uint256 vol,
        uint256 timeToExpiry,
        uint256 riskFreeRate
    ) external pure returns (uint256 price) {
        int256 s = int256(spot);
        int256 k = int256(strike);
        int256 v = int256(vol);
        int256 t = int256(timeToExpiry);
        int256 r = int256(riskFreeRate);

        (int256 d1, int256 d2) = _d1d2(s, k, v, t, r);

        // C = S * N(d1) - K * e^(-rT) * N(d2)
        int256 T = (t * ONE) / int256(SECONDS_PER_YEAR);
        int256 nd1 = FixedPointMath.normalCdf(d1);
        int256 nd2 = FixedPointMath.normalCdf(d2);
        int256 discount = FixedPointMath.exp(-(r.mulDown(T)));

        int256 callPrice = s.mulDown(nd1) - k.mulDown(discount).mulDown(nd2);
        price = callPrice > 0 ? uint256(callPrice) : 0;
    }

    /// @notice Calculate BSM put price via put-call parity
    /// @return price Put option price (18 dec)
    function bsmPutPrice(
        uint256 spot,
        uint256 strike,
        uint256 vol,
        uint256 timeToExpiry,
        uint256 riskFreeRate
    ) external pure returns (uint256 price) {
        int256 s = int256(spot);
        int256 k = int256(strike);
        int256 v = int256(vol);
        int256 t = int256(timeToExpiry);
        int256 r = int256(riskFreeRate);

        (int256 d1, int256 d2) = _d1d2(s, k, v, t, r);

        // P = K * e^(-rT) * N(-d2) - S * N(-d1)
        int256 T = (t * ONE) / int256(SECONDS_PER_YEAR);
        int256 nNegD1 = FixedPointMath.normalCdf(-d1);
        int256 nNegD2 = FixedPointMath.normalCdf(-d2);
        int256 discount = FixedPointMath.exp(-(r.mulDown(T)));

        int256 putPrice = k.mulDown(discount).mulDown(nNegD2) - s.mulDown(nNegD1);
        price = putPrice > 0 ? uint256(putPrice) : 0;
    }

    // ========================================================================
    //                             GREEKS
    // ========================================================================

    /// @notice Calculate option delta
    /// @return delta Delta value (18 dec, signed: negative for puts)
    function calcDelta(
        uint256 spot,
        uint256 strike,
        uint256 vol,
        uint256 timeToExpiry,
        bool isCall
    ) external pure returns (int256 delta) {
        (int256 d1,) = _d1d2(
            int256(spot), int256(strike), int256(vol),
            int256(timeToExpiry), 0 // r=0 for crypto
        );

        if (isCall) {
            // delta_call = N(d1)
            delta = FixedPointMath.normalCdf(d1);
        } else {
            // delta_put = N(d1) - 1
            delta = FixedPointMath.normalCdf(d1) - ONE;
        }
    }

    /// @notice Calculate option gamma
    /// @return gamma Gamma value (18 dec)
    function calcGamma(
        uint256 spot,
        uint256 strike,
        uint256 vol,
        uint256 timeToExpiry
    ) external pure returns (uint256 gamma) {
        int256 s = int256(spot);
        int256 v = int256(vol);
        int256 t = int256(timeToExpiry);

        (int256 d1,) = _d1d2(s, int256(strike), v, t, 0);

        // gamma = n(d1) / (S * vol * sqrt(T))
        int256 T = (t * ONE) / int256(SECONDS_PER_YEAR);
        int256 sqrtT = FixedPointMath.sqrt(T);
        int256 pdf = FixedPointMath.normalPdf(d1);
        int256 denom = s.mulDown(v).mulDown(sqrtT);

        if (denom == 0) return 0;
        int256 g = pdf.divDown(denom);
        gamma = g > 0 ? uint256(g) : 0;
    }

    /// @notice Calculate option theta (daily decay, negative for long positions)
    /// @return theta Daily theta (18 dec, signed)
    function calcTheta(
        uint256 spot,
        uint256 strike,
        uint256 vol,
        uint256 timeToExpiry,
        bool isCall
    ) external pure returns (int256 theta) {
        int256 s = int256(spot);
        int256 k = int256(strike);
        int256 v = int256(vol);
        int256 t = int256(timeToExpiry);

        (int256 d1, int256 d2) = _d1d2(s, k, v, t, 0);

        int256 T = (t * ONE) / int256(SECONDS_PER_YEAR);
        int256 sqrtT = FixedPointMath.sqrt(T);
        int256 pdf = FixedPointMath.normalPdf(d1);

        // First term: -(S * n(d1) * vol) / (2 * sqrt(T))
        int256 term1 = -(s.mulDown(pdf).mulDown(v)).divDown(2 * sqrtT);

        // For r=0 (crypto), the rK term vanishes
        // theta_call = term1 (annualized)
        // theta_put = term1 (annualized, same when r=0)
        // Convert to daily: divide by 365.25
        int256 annualTheta;
        if (isCall) {
            annualTheta = term1;
        } else {
            annualTheta = term1;
        }

        theta = annualTheta / 365;
    }

    /// @notice Calculate option vega (per 1% vol move)
    /// @return vega Vega value (18 dec)
    function calcVega(
        uint256 spot,
        uint256 strike,
        uint256 vol,
        uint256 timeToExpiry
    ) external pure returns (uint256 vega) {
        int256 s = int256(spot);
        int256 t = int256(timeToExpiry);

        (int256 d1,) = _d1d2(s, int256(strike), int256(vol), t, 0);

        int256 T = (t * ONE) / int256(SECONDS_PER_YEAR);
        int256 sqrtT = FixedPointMath.sqrt(T);
        int256 pdf = FixedPointMath.normalPdf(d1);

        // vega = S * n(d1) * sqrt(T)
        // Divided by 100 to express per 1% vol move
        int256 v = s.mulDown(pdf).mulDown(sqrtT) / 100;
        vega = v > 0 ? uint256(v) : 0;
    }

    // ========================================================================
    //                       STRIKE SELECTION
    // ========================================================================

    /// @notice Find optimal strike for a given target delta via binary search
    /// @param spot Current spot price
    /// @param vol Implied volatility
    /// @param timeToExpiry Time to expiry in seconds
    /// @param targetDeltaBps Target delta in bps (e.g. 2500 = 0.25)
    /// @param isCall True for call, false for put
    /// @return strike Optimal strike price
    function findStrikeByDelta(
        uint256 spot,
        uint256 vol,
        uint256 timeToExpiry,
        uint256 targetDeltaBps,
        bool isCall
    ) external pure returns (uint256 strike) {
        // For OTM calls: strike > spot, delta decreases as strike increases
        // For OTM puts: strike < spot, |delta| decreases as strike decreases
        // Binary search range: [0.5 * spot, 3 * spot]

        int256 targetDelta = int256(targetDeltaBps) * ONE / 10000;
        uint256 lo;
        uint256 hi;

        if (isCall) {
            lo = spot;
            hi = spot * 3;
        } else {
            lo = spot / 3;
            hi = spot;
        }

        // 40 iterations gives ~1e-12 precision relative to range
        for (uint256 i = 0; i < 40; i++) {
            uint256 mid = (lo + hi) / 2;
            if (mid == 0) mid = 1;

            (int256 d1,) = _d1d2(
                int256(spot), int256(mid), int256(vol),
                int256(timeToExpiry), 0
            );

            int256 delta;
            if (isCall) {
                delta = FixedPointMath.normalCdf(d1);
                // For calls, delta decreases as strike increases
                if (delta > targetDelta) {
                    lo = mid;
                } else {
                    hi = mid;
                }
            } else {
                delta = FixedPointMath.normalCdf(d1) - ONE;
                // For puts, delta is negative. |delta| decreases as strike decreases
                if (-delta > targetDelta) {
                    hi = mid;
                } else {
                    lo = mid;
                }
            }

            if (hi - lo <= 1e15) break; // $0.001 precision
        }

        strike = (lo + hi) / 2;
    }

    // ========================================================================
    //                        EWMA VOLATILITY
    // ========================================================================

    /// @notice Initialize a vol window for an asset
    function initVolWindow(address asset, bytes32 window, uint256 initialVol, uint256 lambda) external onlyOwner {
        volData[asset][window] = VolWindow({
            vol: initialVol,
            lastUpdate: block.timestamp,
            lambda: lambda
        });
    }

    /// @notice Update EWMA volatility for an asset
    /// @param asset Asset address
    /// @param window Window label (W_1H, W_4H, etc.)
    /// @param returnSq Squared log-return observation (18 dec)
    function updateVol(address asset, bytes32 window, uint256 returnSq) external onlyOwner {
        VolWindow storage vw = volData[asset][window];
        require(vw.lastUpdate > 0, "Window not initialized");

        // EWMA variance: var_t = lambda * var_{t-1} + (1-lambda) * r²
        uint256 oldVar = (vw.vol * vw.vol) / 1e18;
        uint256 newVar = (vw.lambda * oldVar + (1e18 - vw.lambda) * returnSq) / 1e18;

        // vol = sqrt(variance)
        vw.vol = uint256(FixedPointMath.sqrt(int256(newVar)));
        vw.lastUpdate = block.timestamp;
        emit VolUpdated(asset, window, vw.vol);
    }

    /// @notice Get blended vol across multiple windows
    /// @dev Weight: 40% 1d + 30% 7d + 20% 4h + 10% 30d
    function getBlendedVol(address asset) external view returns (uint256) {
        uint256 v1d = volData[asset][W_1D].vol;
        uint256 v7d = volData[asset][W_7D].vol;
        uint256 v4h = volData[asset][W_4H].vol;
        uint256 v30d = volData[asset][W_30D].vol;
        return (v1d * 40 + v7d * 30 + v4h * 20 + v30d * 10) / 100;
    }
}
