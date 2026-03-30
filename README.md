# Nomad Protocol

> DeFi의 QYLD. USDC 넣으면 35% APR. 자동. 끝.

Automated options strategy protocol on **Hyperliquid** (HyperEVM + HyperCore).

## Architecture

```
User → USDC Deposit → NomadVault (ERC-4626)
                          ↓
                  Strategy Module (CC, CSP, IC)
                          ↓
                  Rysk RFQ → Option Sell → Premium
                          ↓
                  Delta Hedge → HyperCore Perps
                          ↓
                  Settlement → Auto-roll → Repeat
```

## Key Components

| Module | Description |
|--------|-------------|
| **NomadVault** | ERC-4626 vault with epoch management, fee collection |
| **CoveredCall** | Sell calls via Rysk RFQ, collect premium |
| **CashSecuredPut** | Sell puts via Rysk RFQ, collect premium |
| **PricingEngine** | BSM pricing, EWMA vol, Greeks, strike selection |
| **DeltaHedger** | HyperCore perp hedging via CoreWriter |
| **RiskManager** | Portfolio Greeks, max drawdown, exposure limits |

## Strategies

| Strategy | Target APR | Phase |
|----------|-----------|-------|
| Covered Call | 20-55% | Phase 1 (Q3 2026) |
| Cash-Secured Put | 18-50% | Phase 1 (Q3 2026) |
| Iron Condor | 15-45% | Phase 2 (Q4 2026) |
| Protective Put | Insurance | Phase 2 |
| Bull Call Spread | Variable | Phase 2 |
| Straddle | Variable | Phase 2 |

## Revenue Model

- Performance Fee: 10-20% of profits
- Management Fee: 1-2% annual on TVL
- Early Exit Fee: 0.5-1% (mid-epoch)

## Dependencies

- [hyper-evm-lib](https://github.com/hyperliquid-dev/hyper-evm-lib) — CoreWriter, Precompiles
- [Rysk Finance](https://github.com/rysk-finance) — RFQ, Ciao settlement
- [OpenZeppelin](https://github.com/OpenZeppelin/openzeppelin-contracts) — ERC-4626, access control

## Development

```bash
forge build
forge test
forge test -vvv  # verbose
```

## License

MIT
