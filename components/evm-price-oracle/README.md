# EVM Price Oracle

A WAVS component that fetches live cryptocurrency prices from CoinMarketCap and submits them on-chain. The reference Rust implementation — also available in [Go](../golang-evm-price-oracle/) and [TypeScript](../js-evm-price-oracle/).

## What it does

1. Receives a CoinMarketCap cryptocurrency ID as trigger input
2. Fetches the current price from the CMC API
3. Returns ABI-encoded price data for on-chain storage

**Example output:**
```json
{"symbol": "BTC", "price": 83241.50, "timestamp": "2026-03-09T15:00:00"}
```

## How it works

```
Trigger input: CMC coin ID (e.g. "1" for Bitcoin)
        │
        ▼
   [evm-price-oracle component]
   GET https://pro-api.coinmarketcap.com/v1/cryptocurrency/quotes/latest?id=1
        │
        ▼
   Parse price + metadata
        │
        ▼
   WasmResponse { payload: abi_encoded(PriceResult) }
```

## Config

Requires a CoinMarketCap API key set as a WAVS service config variable:

```toml
[config]
CMC_API_KEY = "your-api-key-here"
```

Get a free key at [coinmarketcap.com/api](https://coinmarketcap.com/api/).

## Running

```bash
./scripts/deploy-erc8004.sh  # or your price oracle deploy script
```

## Key files

- `src/lib.rs` — `run()` entrypoint
- `src/trigger.rs` — trigger decoding and output encoding
- `src/solidity.rs` — ABI types for on-chain storage
