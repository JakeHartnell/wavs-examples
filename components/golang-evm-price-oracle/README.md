# Go EVM Price Oracle

A WAVS component written in **Go** using [TinyGo](https://tinygo.org/) that fetches live cryptocurrency prices from CoinMarketCap and submits them on-chain.

This example demonstrates writing WAVS components in Go — the same logic, the same on-chain output, a completely different language from the [Rust version](../evm-price-oracle/).

## What it does

1. Receives a CoinMarketCap cryptocurrency ID as trigger input
2. Fetches the current price from the CMC public API
3. Returns the result as ABI-encoded JSON for on-chain submission

**Output:**
```json
{"symbol":"BTC","price":83241.50,"timestamp":"2026-03-09T15:00:00"}
```

## How it works

The component is compiled with TinyGo targeting `wasip2` — WASM with WASI Preview 2 interfaces. It uses:

- **`wit-bindgen-go`** — generates Go bindings from the `wavs:operator@2.7.0` WIT world
- **Raw WASI HTTP bindings** — direct `wasi:http/outgoing-handler@0.2.0` calls (no third-party HTTP library needed)
- **Manual ABI encoding** — pure Go, no `cgo`, TinyGo-compatible

### Key files

| File | Purpose |
|------|---------|
| `src/main.go` | Component entrypoint, WAVS export wiring |
| `src/trigger.go` | Decode EVM trigger events + ABI encode output |
| `src/cmc.go` | CoinMarketCap API fetch + parse |
| `src/http.go` | Raw WASI HTTP client (no external deps) |
| `gen/` | Auto-generated Go bindings (from `make gen-bindings`) |

## Build

### Prerequisites

- [TinyGo](https://tinygo.org/getting-started/install/) 0.40.1+
- [Go](https://go.dev/dl/) 1.23+
- [`wkg`](https://github.com/bytecodealliance/wkg) (for WIT package building)
- [`wit-bindgen-go`](https://github.com/bytecodealliance/go-modules): `go install go.bytecodealliance.org/cmd/wit-bindgen-go@latest`

```bash
make wasi-build
```

The compiled component is written to `../../compiled/golang_evm_price_oracle.wasm`.

### Regenerating bindings

If the `wavs:operator` WIT world changes, regenerate the Go bindings:

```bash
make gen-bindings
```

## Test locally

```bash
# Using wavs-cli via Docker (Bitcoin, CMC ID = 1)
make wasi-exec COMPONENT_FILENAME=golang_evm_price_oracle.wasm INPUT_DATA="1"

# Ethereum = CMC ID 1027
make wasi-exec COMPONENT_FILENAME=golang_evm_price_oracle.wasm INPUT_DATA="1027"
```

## Language comparison

| | Rust | Go | TypeScript |
|---|---|---|---|
| Output size | ~507 KB | ~1.3 MB | ~15 MB |
| Build time | ~30s | ~5s | ~20s |
| HTTP client | Raw WASI | Raw WASI | Native fetch |
| Async | `block_on` | Sync | `async/await` |
| ABI encoding | `alloy-sol-types` | Manual | `ethers.js` |

Go hits a sweet spot: familiar language, fast builds, reasonable output size.

## Notes on TinyGo + WAVS

- TinyGo's `wasip2` target requires the `--wit-package` flag pointing to the WAVS operator WIT package
- Only the `gen/` bindings that are actually imported are compiled into the final WASM (dead code elimination)
- `encoding/json`, `strconv`, `strings`, `math` — standard library packages that work with TinyGo
- No `reflect`, no `net/http` — TinyGo doesn't support these in WASM; use WASI bindings directly
