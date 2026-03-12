# TypeScript/JS EVM Price Oracle

A WAVS component written in **TypeScript** using [@bytecodealliance/componentize-js](https://github.com/bytecodealliance/componentize-js) that fetches live cryptocurrency prices from CoinMarketCap and submits them on-chain.

This example demonstrates writing WAVS components in TypeScript — same logic, same on-chain output, using the full JS ecosystem.

## What it does

1. Receives a CoinMarketCap cryptocurrency ID as trigger input
2. Fetches the current price from the CMC public API using native `fetch()`
3. Returns the result as ABI-encoded JSON for on-chain submission

**Output:**
```json
{"symbol":"BTC","price":83241.50,"timestamp":"2026-03-09T15:00:00"}
```

## How it works

TypeScript is compiled to a WASM component using `componentize-js`, which embeds [SpiderMonkey](https://spidermonkey.dev/) (Firefox's JS engine) in the WASM binary. This means:

- **Full JS spec compliance** — async/await, Promises, native `fetch()`, all work
- **Large binary** (~15MB) — SpiderMonkey is included in every component
- **No build complexity** — if it runs in Node, it (mostly) runs as a WASM component

The WIT bindings are generated from the `wavs:operator@2.7.0` WIT world using `jco types`.

### Key files

| File | Purpose |
|------|---------|
| `index.ts` | Component entrypoint, CoinMarketCap logic |
| `trigger.ts` | Decode EVM trigger events + ABI encode output |
| `out/` | Generated TS type bindings + compiled JS |

## Build

### Prerequisites

- [Node.js](https://nodejs.org/) 18+
- [`wkg`](https://github.com/bytecodealliance/wkg) (for WIT package building)
- `wasm-tools` (for WIT conversion)

```bash
npm install
make wasi-build
```

The compiled component is written to `../../compiled/js_evm_price_oracle.wasm`.

### How the build pipeline works

```
WIT files ──wkg──▶ wavs_operator_2_7_0.wasm
                           │
                    jco types ▼
              TypeScript type definitions
                           │
               index.ts ──tsc──▶ index.js
               trigger.ts         trigger.js
                           │
                    esbuild ▼
                       out/out.js  (single bundled file)
                           │
              jco componentize ▼
               js_evm_price_oracle.wasm  ✅
```

## Test locally

```bash
# Bitcoin (CMC ID 1)
make wasi-exec COMPONENT_FILENAME=js_evm_price_oracle.wasm INPUT_DATA="1"

# Ethereum (CMC ID 1027)  
make wasi-exec COMPONENT_FILENAME=js_evm_price_oracle.wasm INPUT_DATA="1027"
```

## Notes on componentize-js + WAVS

### WIT package must be built from local files

The `wavs:operator@2.7.0` WIT world isn't on the public registry yet. We build it locally:

```bash
# In the wavs-examples root:
wkg wit build --wit-dir ./wit -o wavs_operator_2_7_0.wasm
```

Then convert to WIT text for `jco componentize`:

```bash
wasm-tools component wit wavs_operator_2_7_0.wasm -o wavs_operator_2_7_0.wit
```

### API changes from wavs:worker@0.4.0

If you're porting from the old `wavs-foundry-template` JS example, note these breaking changes:

| | Old (`wavs:worker@0.4.0`) | New (`wavs:operator@2.7.0`) |
|---|---|---|
| World | `layer-trigger-world` | `wavs-world` |
| `run` return | `Promise<WasmResponse>` | `Promise<WasmResponse[]>` |
| EVM log topics | `log.topics` | `log.data.topics` |
| EVM log data | `log.data` (bytes) | `log.data.data` (bytes) |
| WasmResponse | `{payload, ordering}` | `{payload, ordering, eventIdSalt}` |

### Why is it 15MB?

SpiderMonkey — the full Firefox JS engine — is compiled into every JS WASM component. This is the trade-off: you get a complete, spec-compliant JS runtime, at the cost of ~13MB baseline. For most use cases (price feeds, data transforms, API calls), this is fine.
