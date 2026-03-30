// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FixedPointMath
/// @notice Fixed-point arithmetic library for BSM pricing (18-decimal precision)
/// @dev All values use 1e18 scaling unless noted. Signed math uses int256.
library FixedPointMath {
    int256 internal constant ONE = 1e18;
    int256 internal constant TWO = 2e18;
    int256 internal constant HALF = 5e17;
    int256 internal constant PI_2 = 2_506_628_274_631_000_502; // sqrt(2*pi) * 1e18

    // ln(2) * 1e18
    int256 internal constant LN2 = 693_147_180_559_945_309;

    // --- Multiplication / Division ---

    function mulDown(int256 a, int256 b) internal pure returns (int256) {
        return (a * b) / ONE;
    }

    function divDown(int256 a, int256 b) internal pure returns (int256) {
        return (a * ONE) / b;
    }

    // --- Absolute value ---

    function abs(int256 x) internal pure returns (int256) {
        return x >= 0 ? x : -x;
    }

    // --- Square root (Babylonian, unsigned input, signed output) ---

    /// @notice Integer square root of x * 1e18 (i.e. sqrt in 18-decimal fixed point)
    /// @param x Non-negative 18-decimal fixed-point number
    /// @return y sqrt(x) in 18-decimal fixed-point
    function sqrt(int256 x) internal pure returns (int256 y) {
        require(x >= 0, "sqrt of negative");
        if (x == 0) return 0;

        // Scale up by 1e18 so sqrt preserves 18-decimal precision
        uint256 xu = uint256(x);
        uint256 scaled = xu * 1e18;

        // Babylonian method
        uint256 z = (scaled + 1) / 2;
        uint256 result = scaled;
        while (z < result) {
            result = z;
            z = (scaled / z + z) / 2;
        }
        y = int256(result);
    }

    // --- Natural logarithm (ln) ---
    // Uses the identity: ln(x) = ln(x / 2^k) + k * ln(2)
    // Then uses a Taylor series around 1 for ln(1 + u) where u is small.

    /// @notice Natural log of x (18-decimal fixed point). x must be > 0.
    /// @param x Positive 18-dec fixed-point number
    /// @return result ln(x) in 18-dec fixed-point (can be negative)
    function ln(int256 x) internal pure returns (int256 result) {
        require(x > 0, "ln of non-positive");

        // Range reduction: divide by 2 until x is in [0.5, 1)
        // Actually, let's use [1, 2) which is easier for Taylor around 1
        int256 k = 0;

        // Bring x into [ONE, TWO)
        while (x < ONE) {
            x = x * 2;
            k -= ONE;
        }
        while (x >= TWO) {
            x = x / 2;
            k += ONE;
        }

        // Now x is in [1e18, 2e18). Compute ln(x) via ln(1+u) where u = x - 1
        // ln(1+u) = u - u²/2 + u³/3 - u⁴/4 + ... (converges for |u| < 1)
        int256 u = x - ONE;
        int256 term = u;
        int256 sum = term;

        // 12 iterations for good precision (|u| <= 1)
        for (int256 i = 2; i <= 12; i++) {
            term = mulDown(term, u) * (-1);
            sum += term / i;
        }

        // ln(x_original) = sum + k * ln(2)
        result = sum + mulDown(k, LN2);
    }

    // --- Exponential (e^x) ---
    // Uses range reduction: e^x = 2^k * e^r where r is small
    // Then Taylor series for e^r

    /// @notice Compute e^x in 18-decimal fixed point
    /// @param x Exponent (18-dec, can be negative)
    /// @return result e^x (18-dec). Returns 0 if result underflows.
    function exp(int256 x) internal pure returns (int256 result) {
        // Clamp to avoid overflow: e^(135) ~ 4.15e58 which fits int256
        // e^(-42) ~ 5.7e-19 which rounds to 0 at 18 decimals
        if (x < -42 * ONE) return 0;
        if (x > 135 * ONE) revert("exp overflow");
        if (x == 0) return ONE;

        // Range reduction: x = k * ln(2) + r, where k = floor(x / ln2)
        // e^x = 2^k * e^r
        int256 k = x / LN2;
        int256 r = x - k * LN2;

        // Taylor series for e^r: 1 + r + r²/2! + r³/3! + ...
        // r is in (-ln2, ln2) ≈ (-0.693, 0.693)
        int256 term = ONE;
        int256 sum = ONE;
        for (int256 i = 1; i <= 16; i++) {
            term = mulDown(term, r) / i;
            sum += term;
            if (abs(term) < 1) break; // negligible contribution
        }

        // Multiply by 2^k
        if (k >= 0) {
            result = sum;
            for (int256 i = 0; i < k; i++) {
                result = result * 2;
            }
        } else {
            result = sum;
            int256 neg = -k;
            for (int256 i = 0; i < neg; i++) {
                result = result / 2;
            }
        }
    }

    // --- Standard Normal CDF: N(x) ---
    // Abramowitz & Stegun approximation (formula 26.2.17), accurate to ~1e-5

    /// @notice Standard normal CDF N(x)
    /// @param x Input (18-dec fixed-point)
    /// @return cdf N(x) in [0, 1e18]
    function normalCdf(int256 x) internal pure returns (int256 cdf) {
        // Constants for Abramowitz & Stegun
        int256 a1 = 254_829_592_000_000_000;   // 0.254829592 * 1e18
        int256 a2 = -284_496_736_000_000_000;  // -0.284496736 * 1e18
        int256 a3 = 1_421_413_741_000_000_000; // 1.421413741 * 1e18
        int256 a4 = -1_453_152_027_000_000_000;// -1.453152027 * 1e18
        int256 a5 = 1_061_405_429_000_000_000; // 1.061405429 * 1e18
        int256 p = 327_591_100_000_000_000;     // 0.3275911 * 1e18

        bool neg = x < 0;
        int256 ax = abs(x);

        // t = 1 / (1 + p * |x|)
        int256 t = divDown(ONE, ONE + mulDown(p, ax));

        // Horner's method: poly = t*(a1 + t*(a2 + t*(a3 + t*(a4 + t*a5))))
        int256 poly = mulDown(t, a5);
        poly = mulDown(t, a4 + poly);
        poly = mulDown(t, a3 + poly);
        poly = mulDown(t, a2 + poly);
        poly = mulDown(t, a1 + poly);

        // n(x) = exp(-x²/2) / sqrt(2π)
        int256 xsq = mulDown(ax, ax);
        int256 expVal = exp(-xsq / 2);
        int256 pdf = divDown(expVal, PI_2);

        // N(x) = 1 - n(x) * poly  (for x >= 0)
        cdf = ONE - mulDown(pdf, poly);

        // Symmetry: N(-x) = 1 - N(x)
        if (neg) {
            cdf = ONE - cdf;
        }

        // Clamp to [0, 1e18]
        if (cdf < 0) cdf = 0;
        if (cdf > ONE) cdf = ONE;
    }

    // --- Standard Normal PDF: n(x) ---

    /// @notice Standard normal PDF n(x) = exp(-x²/2) / sqrt(2π)
    /// @param x Input (18-dec)
    /// @return pdf n(x) (18-dec)
    function normalPdf(int256 x) internal pure returns (int256 pdf) {
        int256 xsq = mulDown(x, x);
        int256 expVal = exp(-xsq / 2);
        pdf = divDown(expVal, PI_2);
    }
}
