# Nomad Finance

DeFi vault protocol built on ERC-4626 with integrated strategy, pricing, hedging, and risk management modules.

## Architecture

- **Vault** — ERC-4626 compliant vault for asset management
- **Strategy** — Pluggable yield strategies
- **Pricing** — On-chain asset pricing
- **Hedge** — Delta-neutral hedging via options/perps
- **Risk** — Portfolio risk assessment and limits

## Protocol Integrations

- **HyperCore** — Perpetual DEX for delta hedging
- **Rysk** — Options protocol for volatility strategies

## Development

```bash
# Build
forge build

# Test
forge test

# Deploy
forge script script/Deploy.s.sol --rpc-url <RPC_URL> --broadcast
```

## License

MIT
