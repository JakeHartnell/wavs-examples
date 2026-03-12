# Python EVM Price Oracle

A WAVS component that fetches live cryptocurrency prices from CoinMarketCap and writes them on-chain — written in **Python** and compiled to WASM using [componentize-py](https://github.com/bytecodealliance/componentize-py).

This is the Python entry in the multi-language price oracle series (alongside [Rust](../evm-price-oracle/), [TypeScript](../js-evm-price-oracle/), and [Go](../golang-evm-price-oracle/)).

## What it does

1. **Triggered on-chain** by a `NewTrigger(bytes)` event containing a CoinMarketCap ID (e.g. `"1"` = Bitcoin)
2. **Fetches the price** from the public CMC API via WASI outgoing HTTP
3. **Returns ABI-encoded** `DataWithId { triggerId, bytes }` for on-chain submission

Output is JSON:
```json
{"symbol": "BTC", "price": 82451.23, "timestamp": "2026-03-12T14:00:00"}
```

## How it works

### Python → WASM via componentize-py

[componentize-py](https://github.com/bytecodealliance/componentize-py) embeds a full **CPython 3.12** interpreter into the WASM component. It takes:
- A WIT world definition (the WAVS operator interface)
- A Python module implementing that world

And produces a standard WebAssembly Component Model binary.

**Tradeoffs vs Rust/Go:**

| | Rust | Go (TinyGo) | TypeScript | Python |
|---|---|---|---|---|
| WASM size | ~100KB | ~1.3MB | ~15MB | ~19MB |
| Build time | ~30s | ~15s | ~10s | ~10s |
| Runtime | native | TinyGo | SpiderMonkey | CPython |
| Package ecosystem | cargo | go modules | npm | pip |

The size difference is the main tradeoff — Python components require `max_body_size_mb` to be increased in `wavs.toml` (default 15MB → 50MB).

### HTTP without poll_loop

componentize-py's bundled `poll_loop.py` targets the `wasi:http/proxy` world where the HTTP types module is `wit_world.imports.types`. In the WAVS world they're named `wasi_http_types`. We implement a minimal blocking HTTP client directly — no asyncio needed in a single-threaded WASM context:

```python
future = outgoing_handler.handle(req, None)
while True:
    result = future.get()
    if result is None:
        wasi_poll.poll([future.subscribe()])  # yield until ready
    else:
        response = result.value.value
        break
```

### ABI encoding in pure Python

ABI decode/encode is implemented manually in `trigger.py` (no `eth_abi` dependency) — ported directly from the Go implementation. The structures are simple enough that `struct.pack` + slice arithmetic is all you need.

## File structure

```
python-evm-price-oracle/
├── component.py      # WitWorld entrypoint — run() function
├── trigger.py        # ABI decode (NewTrigger event) + encode (DataWithId)
├── http_client.py    # Blocking HTTP GET using WASI outgoing-handler
├── wit-clean/        # Simplified WIT (strips @unstable annotations unsupported by componentize-py)
│   ├── operator.wit
│   └── deps/
├── Makefile
└── README.md
```

`wit-clean/` is a copy of the project WIT that omits `wasi:keyvalue` and `wasi:tls` (both use `@unstable` annotations that componentize-py 0.21.0 doesn't support). This is a known limitation — tracked upstream.

## Building

### Prerequisites

```bash
# Install componentize-py (one-time setup)
make install-deps

# Or manually:
curl https://bootstrap.pypa.io/get-pip.py | python3 - --user --break-system-packages
pip install componentize-py==0.21.0 --user --break-system-packages
```

### Build

```bash
make wasi-build
# Output: ../../compiled/python_evm_price_oracle.wasm (~19MB after stripping)
```

The build compiles via componentize-py, then strips debug info with `wasm-tools strip` (~41MB → ~19MB).

### IDE bindings (optional)

```bash
make gen-bindings
# Generates wavs_guest/ with Python type stubs for IDE autocompletion
```

## Running end-to-end

### 1. Increase WAVS body size limit

The Python WASM is ~19MB. The WAVS node default limit is 15MB. Add to `wavs.toml`:

```toml
[wavs]
max_body_size_mb = 50
```

Then restart the WAVS node.

### 2. Deploy

```bash
cd ../../  # repo root
./scripts/deploy-python-price-oracle.sh

# Custom coin:
CMC_ID=1027 ./scripts/deploy-python-price-oracle.sh  # ETH
```

## CoinMarketCap IDs

| ID | Symbol | Name |
|---|---|---|
| 1 | BTC | Bitcoin |
| 1027 | ETH | Ethereum |
| 5805 | AVAX | Avalanche |
| 74 | DOGE | Dogecoin |
| 5426 | SOL | Solana |

Any ID from https://coinmarketcap.com/api/documentation/v1/ works.
