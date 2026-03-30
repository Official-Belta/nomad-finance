# Nomad Finance — Claude Code Context

## What is this?
Automated options strategy protocol on Hyperliquid.
"DeFi의 QYLD. USDC 넣으면 35% APR. 자동. 끝."

## Architecture
```
유저 → USDC 예치 → NomadVault (ERC-4626)
                        ↓
                Strategy Module (CC, CSP, IC)
                        ↓
                Rysk RFQ → Option 매도 → Premium 수취
                        ↓
                Delta Hedge → HyperCore perp (CoreWriter)
                        ↓
                Settlement → Auto-roll → 반복
```

## Chain & Dependencies
- **Chain:** Hyperliquid (HyperEVM + HyperCore)
- **Options:** Rysk Finance RFQ (100% 의존)
- **Hedging:** HyperCore perps via CoreWriter + Precompiles
- **Libraries:** hyper-evm-lib (CoreWriter, PrecompileLib), Rysk ciao-protocol

## Key Contracts
- `src/vault/NomadVault.sol` — ERC-4626 vault with epoch management
- `src/strategy/CoveredCall.sol` — Covered Call via Rysk RFQ
- `src/strategy/CashSecuredPut.sol` — Cash-Secured Put via Rysk RFQ
- `src/pricing/PricingEngine.sol` — BSM + EWMA vol + Greeks
- `src/hedge/DeltaHedger.sol` — HyperCore perp delta hedging
- `src/risk/RiskManager.sol` — Portfolio Greeks, max loss limits
- `src/interfaces/hypercore/` — CoreWriter, Precompile interfaces
- `src/interfaces/rysk/` — Rysk RFQ, Ciao protocol interfaces

## Build & Test
```bash
forge build
forge test
```

## Phase 1 Target (Q3 2026)
- Covered Call + Cash-Secured Put vaults
- TVL cap $1M
- Target APR: 20-55%

## Revenue
- Performance fee: 10-20% of profits
- Management fee: 1-2% annual on TVL
- Early exit fee: 0.5-1% (mid-epoch)
