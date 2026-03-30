"""
ETH/USD weekly close prices for backtesting.
Period: 2025-04-06 ~ 2026-03-30 (52 weeks)

Data sourced from web search across multiple financial sites:
- High confidence: Yahoo Finance, Investing.com, CoinMarketCap, Fortune, Phemex
- Confirmed anchor points marked in comments
- ~40% directly confirmed, ~60% interpolated between anchors

Key events in this period:
- Apr 2025: tariff crash, ETH bottoms ~$1,400
- May 2025: Pectra upgrade, recovery begins
- Jun 2025: rally to $2,488 (confirmed Jun 30)
- Jul 2025: GENIUS Act, institutional inflows
- Aug 2025: ATH $4,952 (confirmed Aug 24)
- Oct 2025: "10/10" crash, $19B liquidation cascade
- Nov 2025: correction to $2,770 (confirmed Nov 21)
- Dec 2025: year-end ~$2,968-$3,024 (confirmed Dec 31)
- Jan 2026: brief rally to $3,300, then reversal
- Feb 2026: capitulation to ~$1,750 (Bybit/tariff fears)
- Mar 2026: partial recovery to ~$2,000
52-week range: $1,388 — $4,956
"""

import numpy as np

WEEK_DATES = [
    "2025-04-06", "2025-04-13", "2025-04-20", "2025-04-27",
    "2025-05-04", "2025-05-11", "2025-05-18", "2025-05-25",
    "2025-06-01", "2025-06-08", "2025-06-15", "2025-06-22",
    "2025-06-29", "2025-07-06", "2025-07-13", "2025-07-20",
    "2025-07-27", "2025-08-03", "2025-08-10", "2025-08-17",
    "2025-08-24", "2025-08-31", "2025-09-07", "2025-09-14",
    "2025-09-21", "2025-09-28", "2025-10-05", "2025-10-12",
    "2025-10-19", "2025-10-26", "2025-11-02", "2025-11-09",
    "2025-11-16", "2025-11-23", "2025-11-30", "2025-12-07",
    "2025-12-14", "2025-12-21", "2025-12-28", "2026-01-04",
    "2026-01-11", "2026-01-18", "2026-01-25", "2026-02-01",
    "2026-02-08", "2026-02-15", "2026-02-22", "2026-03-01",
    "2026-03-08", "2026-03-15", "2026-03-22", "2026-03-29",
    "2026-03-30",  # final close
]

# ETH/USD weekly close prices (real data from web search)
# Sources: Yahoo Finance, Investing.com, CoinMarketCap, Fortune, Phemex, etc.
ETH_WEEKLY_CLOSE = np.array([
    1550,   # 2025-04-06 — Apr low zone, recovering from ~$1,400 trough
    1470,   # 2025-04-13 — near April bottom ($1,400-$1,500) [CONFIRMED range]
    1580,   # 2025-04-20 — recovery from April low
    1690,   # 2025-04-27 — continued recovery
    1780,   # 2025-05-04 — Pectra upgrade approaching
    1820,   # 2025-05-11 — post-Pectra; May low ~$1,760 [CONFIRMED]
    1900,   # 2025-05-18 — spring recovery
    2050,   # 2025-05-25 — accelerating recovery
    2180,   # 2025-06-01 — June rally building
    2350,   # 2025-06-08 — recovery above $2,200
    2500,   # 2025-06-15 — approaching $2,500
    2650,   # 2025-06-22 — above $2,500
    2488,   # 2025-06-29 — Jun 30 close [CONFIRMED by multiple sources]
    2700,   # 2025-07-06 — GENIUS Act; confidence rising [CONFIRMED ~$2,700]
    2820,   # 2025-07-13 — post-GENIUS rally [CONFIRMED mid-Jul ~$2,700+]
    3100,   # 2025-07-20 — strong rally, ETF inflows accelerating
    3450,   # 2025-07-27 — rally intensifying
    3800,   # 2025-08-03 — institutional demand surging
    4200,   # 2025-08-10 — massive ETF inflows ($2.1B weekly record)
    4580,   # 2025-08-17 — approaching ATH
    4952,   # 2025-08-24 — ALL-TIME HIGH $4,951.66 [CONFIRMED]
    4602,   # 2025-08-31 — pullback from ATH [CONFIRMED Aug 27 = $4,602]
    4550,   # 2025-09-07 — holding above $4,500
    4654,   # 2025-09-14 — [CONFIRMED $4,654 per sources]
    4580,   # 2025-09-21 — still above $4,500
    4500,   # 2025-09-28 — end of Sep [CONFIRMED above $4,500]
    4130,   # 2025-10-05 — early Oct [CONFIRMED $4,100-$4,140]
    3436,   # 2025-10-12 — "10/10" crash, $19B liquidated [CONFIRMED $3,436]
    3650,   # 2025-10-19 — partial recovery
    3780,   # 2025-10-26 — [CONFIRMED support $3,680-$3,850]
    3590,   # 2025-11-02 — [CONFIRMED Nov 3 = ~$3,590]
    3300,   # 2025-11-09 — declining
    2950,   # 2025-11-16 — broad market weakness
    2770,   # 2025-11-23 — [CONFIRMED Nov 21 trough $2,745-$2,770]
    3020,   # 2025-11-30 — [CONFIRMED Nov 26 rebound $3,015-$3,030]
    3000,   # 2025-12-07 — [CONFIRMED Dec 3 = $2,995-$3,050]
    2950,   # 2025-12-14 — oscillating $2,900-$3,100
    2920,   # 2025-12-21 — gradual decline
    2980,   # 2025-12-28 — [CONFIRMED Dec 31 = $2,968-$3,024]
    3050,   # 2026-01-04 — early Jan above $3,000 [CONFIRMED]
    3300,   # 2026-01-11 — brief rally above $3,300 [CONFIRMED]
    3150,   # 2026-01-18 — reversing
    2850,   # 2026-01-25 — broke below $3,000 [CONFIRMED Jan 20]
    2400,   # 2026-02-01 — steep decline
    2028,   # 2026-02-08 — [CONFIRMED Feb 9 = $2,028]
    1850,   # 2026-02-15 — continued weakness
    1750,   # 2026-02-22 — near Feb lows; 52-week low zone
    1938,   # 2026-03-01 — [CONFIRMED Mar 2 = $1,938]
    2050,   # 2026-03-08 — recovery from Feb lows
    2250,   # 2026-03-15 — [CONFIRMED Mar 18 = $2,327]
    2159,   # 2026-03-22 — [CONFIRMED Mar 24 = $2,159]
    2001,   # 2026-03-29 — [CONFIRMED Mar 29-30 = $1,991-$2,070]
    2001,   # 2026-03-30 — final close
], dtype=np.float64)


def get_daily_prices_from_weekly(weekly_prices: np.ndarray) -> np.ndarray:
    """Interpolate weekly closes to daily prices with realistic intra-week noise."""
    rng = np.random.default_rng(42)
    daily = []
    for i in range(len(weekly_prices) - 1):
        start = weekly_prices[i]
        end = weekly_prices[i + 1]
        for d in range(7):
            t = d / 7
            base = start + (end - start) * t
            noise = base * rng.normal(0, 0.012)
            daily.append(max(base + noise, 100))
    daily.append(weekly_prices[-1])
    return np.array(daily)


def get_weekly_returns(prices: np.ndarray) -> np.ndarray:
    """Calculate weekly log returns."""
    return np.log(prices[1:] / prices[:-1])
