# Python EVM Price Oracle — Implementation Plan

## Overview

Add a Python implementation of the EVM price oracle to `wavs-examples`, joining Rust, JavaScript/TypeScript, and Go. Uses **componentize-py** to compile Python → WASM component targeting the `wavs:operator/wavs-world` WIT world.

This is the first Python WAVS component in the examples repo and validates Python as a first-class WAVS language.

---

## Tool: componentize-py

**What it is:** Bytecode Alliance tool that embeds CPython into a WASM component. It takes a WIT world + a Python module and produces a `.wasm` component file.

**Version:** `0.21.0` (latest stable, supports WASI Preview 2 / 0.2.0)
- PyPI: `componentize-py==0.21.0`
- Wheel for Linux arm64 available: `manylinux_2_28_aarch64.whl` ✅
- Already installed at: `/home/node/.local/bin/componentize-py`

**Confirmed working:** bindings successfully generated from WAVS WIT (with minor WIT simplification — see Build Notes).

---

## Confirmed Python API (from generated bindings)

```python
# component.py
import wit_world
from wit_world.imports import input, output
from typing import List

class WitWorld(wit_world.WitWorld):
    def run(self, trigger_action: input.TriggerAction) -> List[output.WasmResponse]:
        # Implementation here
        # Raise string on error: raise "error message"
        ...
```

**Key types (all confirmed from generated stubs):**

```python
# TriggerAction
trigger_action.data  # Union type: TriggerData_EvmContractEvent | TriggerData_Raw | ...

# TriggerData variants
TriggerData_Raw(value: bytes)                              # CLI testing
TriggerData_EvmContractEvent(value: TriggerDataEvmContractEvent)  # on-chain

# EVM event path
trigger_action.data.value.log           # EvmEventLog
trigger_action.data.value.log.data      # EvmEventLogData
trigger_action.data.value.log.data.data # bytes  ← raw ABI payload

# WasmResponse (output)
output.WasmResponse(
    payload=bytes,
    ordering=None,
    event_id_salt=None
)
```

**HTTP (WASI outgoing-handler, bundled poll_loop.py):**

```python
from poll_loop import PollLoop, send, Stream
from wit_world.imports.wasi_http_types import OutgoingRequest, Fields, Scheme_Https

async def fetch_url(url: str) -> bytes:
    req = OutgoingRequest(Fields.from_list([
        (b"Accept", b"application/json"),
        (b"User-Agent", b"Mozilla/5.0"),
    ]))
    req.set_scheme(Scheme_Https())
    req.set_authority(b"api.coinmarketcap.com")
    req.set_path_with_query(b"/data-api/v3/cryptocurrency/detail?id=1&range=1h")
    
    response = await send(req)
    stream = Stream(response.consume())
    body = bytearray()
    while True:
        chunk = await stream.next()
        if chunk is None:
            break
        body.extend(chunk)
    return bytes(body)

# Wrap async in sync for the WAVS run() function:
import asyncio
loop = PollLoop()
asyncio.set_event_loop(loop)
body = loop.run_until_complete(fetch_url(url))
```

**Note:** `poll_loop.py` is bundled by componentize-py — no extra dependency needed.

---

## ABI Encoding Strategy

**No external libraries needed.** Pure Python byte manipulation, translated directly from the Go implementation (`trigger.go`).

### Decode input (NewTrigger event)

```
Event data layout:
  [0:32]   offset to _triggerInfo bytes (= 0x20)
  [32:64]  length of _triggerInfo bytes
  [64:N]   TriggerInfo ABI bytes

TriggerInfo ABI layout (after skipping 32-byte ABI-prefix):
  [0:32]    triggerId  (uint64, right-aligned)
  [32:64]   creator    (address, right-aligned)
  [64:96]   offset to data bytes (= 0x60)
  [96:128]  length of data bytes
  [128..]   data bytes (CMC ID as UTF-8 string, padded to 32-byte boundary)
```

### Encode output (DataWithId)

```
DataWithId ABI layout:
  [0:32]   triggerId (uint64, right-aligned)
  [32:64]  offset to data bytes (= 0x40)
  [64:96]  length of data bytes
  [96..]   data bytes (JSON price data, padded to 32-byte boundary)
```

Both implemented as simple `struct.pack`/slice operations in `abi.py`.

---

## File Structure

```
components/python-evm-price-oracle/
├── Makefile          # Build + bindings generation
├── README.md         # How-to + explanation
├── component.py      # Main WAVS component (WitWorld class + run())
├── trigger.py        # ABI decode/encode (NewTrigger → TriggerInfo, DataWithId)
└── http_client.py    # Async HTTP helper using WASI outgoing-handler + poll_loop
```

Note: `wit_world/` (generated bindings) is **not** committed — generated at build time.

---

## Build Process

### Step 1: Install componentize-py (one-time)

```bash
# pip not available via pip3 — use python3 -m pip (after get-pip.py)
curl https://bootstrap.pypa.io/get-pip.py | python3 - --user --break-system-packages
/home/node/.local/bin/pip install componentize-py==0.21.0 --user --break-system-packages
```

Already done in this container. The Makefile will check and install if missing.

### Step 2: Generate bindings (optional, for IDE support)

```bash
componentize-py -d ../../wit-clean -w wavs:operator/wavs-world bindings wavs_guest
```

### Step 3: Build WASM component

```bash
componentize-py \
  -d ../../wit-clean \
  -w wavs:operator/wavs-world \
  componentize component \
  -o ../../compiled/python_evm_price_oracle.wasm
```

Output: `compiled/python_evm_price_oracle.wasm`

---

## Build Notes: WIT Simplification

**Problem:** componentize-py 0.21.0 fails on `@unstable` annotations in `wasi:tls@0.2.0-draft`.

**Solution:** Provide a `wit-clean/` directory alongside the component that mirrors `../../wit/` but excludes the TLS include (and wasi:keyvalue which has the same issue). The component doesn't use TLS or keyvalue anyway.

The cleaned WIT:
- ✅ Keep: `wasi:cli/imports`, `wasi:http/types`, `wasi:http/outgoing-handler`, all wavs types
- ❌ Remove: `include wasi:keyvalue/imports@0.2.0-draft2` (has `@unstable`)
- ❌ Remove: `include wasi:tls/imports@0.2.0-draft` (has `@unstable`)
- ❌ Remove: `include wasi:sockets/imports@0.2.0` (not needed for outgoing HTTP)

Alternative: Use the compiled `wavs_operator_2_7_0.wasm` WIT package — but componentize-py `-d` doesn't support binary `.wasm` input, only WIT text directories.

Long-term: file upstream issue with componentize-py for `@unstable` support (or WAVS can remove TLS from the world).

---

## Makefile Design

```makefile
WAVS_WIT_DIR    ?= ./wit-clean
WAVS_WIT_WORLD  ?= wavs:operator/wavs-world
OUTPUT_DIR      ?= ../../compiled
COMPONENTIZE_PY ?= componentize-py

wasi-build: wit-clean/operator.wit
    @echo "🐍 Building Python component: python_evm_price_oracle..."
    @mkdir -p $(OUTPUT_DIR)
    @$(COMPONENTIZE_PY) -d $(WAVS_WIT_DIR) -w $(WAVS_WIT_WORLD) \
        componentize component \
        -o $(OUTPUT_DIR)/python_evm_price_oracle.wasm
    @echo "✅ Built: $(OUTPUT_DIR)/python_evm_price_oracle.wasm"

gen-bindings:
    @$(COMPONENTIZE_PY) -d $(WAVS_WIT_DIR) -w $(WAVS_WIT_WORLD) bindings wavs_guest
    @echo "✅ Bindings generated in wavs_guest/"
```

---

## Component Logic Flow

```
on-chain trigger (NewTrigger event)
    │
    ▼
run(trigger_action: TriggerAction)
    │
    ├─ if TriggerData_Raw → CLI path (raw bytes = CMC ID string)
    │
    └─ if TriggerData_EvmContractEvent → ABI decode path
           │  log.data.data → decode_trigger_info() → (trigger_id, cmc_id_bytes)
           ▼
    cmc_id = int(cmc_id_bytes.decode())
           │
           ▼
    price_data = fetch_price_sync(cmc_id)
           │   GET coinmarketcap.com/data-api/v3/cryptocurrency/detail
           │   → { symbol, price, timestamp }
           ▼
    json_bytes = json.dumps(price_data).encode()
           │
           ├─ if CLI → return WasmResponse(payload=json_bytes)
           │
           └─ if EVM → encode_output(trigger_id, json_bytes)
                        → WasmResponse(payload=abi_encoded)
```

---

## What's Novel / Why This Matters

1. **First Python WAVS component** — validates Python as a target language
2. **No external Python deps** — pure stdlib + WASI bindings (componentize-py bundles CPython)
3. **Demonstrates componentize-py with a real-world WIT world** (not just wasi:http/proxy)
4. **Blog/docs angle**: "You can write WAVS components in Python now" — very accessible for ML/AI developers who live in Python

---

## Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| WASI HTTP binding differences from expected API | Medium | Already confirmed poll_loop.py is bundled; will verify exact method signatures during impl |
| WIT `@unstable` annotation issue | Confirmed | Use `wit-clean/` workaround |
| Large WASM size (CPython is ~20MB) | Confirmed (expected) | Document it; note it's a tradeoff. componentize-py notes output is ~20-30MB |
| Python asyncio + PollLoop edge cases | Low | Proven pattern in componentize-py http examples |

---

## Next Steps

1. Create `wit-clean/` directory with simplified WIT
2. Implement `trigger.py` (ABI decode/encode, translated from Go)
3. Implement `http_client.py` (WASI HTTP + poll_loop wrapper)
4. Implement `component.py` (main `WitWorld` class)
5. Write `Makefile`
6. Build and test with CLI trigger first, then full on-chain test
7. Write `README.md`
