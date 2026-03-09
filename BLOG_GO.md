# Writing WAVS Components in Go

*WASM is language-agnostic. Here's what that actually looks like in practice.*

---

One of WASM's most compelling properties is that it doesn't care what language you wrote your code in. Rust, TypeScript, Go, Python — if it compiles to WebAssembly, it runs. WAVS takes full advantage of this: any language that targets `wasip2` can become a WAVS component.

This post walks through building a real WAVS component in Go — a price oracle that fetches live crypto prices from CoinMarketCap and submits them on-chain.

## Why Go?

Go is everywhere in infrastructure. If you've built a Kubernetes operator, a Docker plugin, or a blockchain node, you've probably written Go. It compiles fast, has excellent tooling, and the standard library is rich. For WAVS components, Go offers:

- **Familiar concurrency model** (even if WASM is single-threaded, the mental model transfers)
- **Strong typing** with clean JSON handling
- **Fast compilation** (~5 seconds for a component)
- **Reasonable output size** (~1.3 MB vs ~15 MB for JS)

The catch: you need [TinyGo](https://tinygo.org/), not standard Go. TinyGo is a Go compiler designed for embedded systems and WebAssembly. It supports the `wasip2` target and works with the WASI Component Model.

## The Setup

Before writing any code, there are two tools to install beyond TinyGo itself:

**`wit-bindgen-go`** — generates Go types from a WIT interface definition:

```bash
go install go.bytecodealliance.org/cmd/wit-bindgen-go@latest
```

**The WIT package** — WAVS components implement a specific WIT world (`wavs:operator@2.7.0`). You build it from the local WIT files:

```bash
# from wavs-examples root
wkg wit build --wit-dir ./wit -o compiled/wavs_operator_2_7_0.wasm
```

Then generate Go bindings:

```bash
wit-bindgen-go generate \
  --world "wavs:operator/wavs-world" \
  --out ./gen \
  --package-root "github.com/your-org/your-component/gen" \
  ../../wit
```

This writes a `gen/` directory with all the Go types for the WAVS world — trigger actions, wasm responses, event types, and the full WASI interface surface.

## The Component

A WAVS component has one job: implement the `run` function defined in the WIT world:

```wit
export run: func(trigger-action: trigger-action) -> result<list<wasm-response>, string>;
```

In Go, this looks like:

```go
package main

import (
    wavsworld "github.com/your-org/component/gen/wavs/operator/wavs-world"
    "go.bytecodealliance.org/cm"
)

func init() {
    wavsworld.Exports.Run = run
}

func run(action wavsworld.TriggerAction) cm.Result[cm.List[wavsworld.WasmResponse], cm.List[wavsworld.WasmResponse], string] {
    triggerID, input, dest := decodeTriggerEvent(action.Data)

    result, err := compute(input, dest)
    if err != nil {
        return cm.Err[...](err.Error())
    }

    return routeResult(triggerID, result, dest)
}

func main() {} // required by wasm-ld, never called
```

The `init()` hook is how you register your implementation with the generated bindings. The `main()` function is empty — required by the linker but never invoked.

## Decoding Triggers

WAVS components receive events in one of two ways:

1. **On-chain**: An EVM contract event, ABI-encoded
2. **CLI**: Raw bytes, for local testing with `make wasi-exec`

In `wavs:operator@2.7.0`, the `TriggerData` type is a Go variant (tagged union):

```go
func decodeTriggerEvent(data inputTypes.TriggerData) (triggerID uint64, input []byte, dest destination) {
    // CLI / local testing path
    if raw := data.Raw(); raw != nil {
        return 0, raw.Slice(), destCLI
    }

    // On-chain EVM event
    evmEvent := data.EvmContractEvent()
    log := evmEvent.Log

    // In @2.7.0, log.Data is EvmEventLogData{Topics, Data}
    // (changed from log.Topics / log.Data directly in @0.4.0)
    triggerInfo := decodeTriggerInfo(log)

    return triggerInfo.TriggerID, triggerInfo.Data, destEthereum
}
```

The `decodeTriggerInfo` function manually ABI-decodes the `NewTrigger` event log into our `TriggerInfo` struct (triggerId, creator, data). We do this without external ABI libraries — pure Go bit manipulation, TinyGo-compatible.

## HTTP Without net/http

Here's the gotcha that surprises every Go developer hitting WASM for the first time: `net/http` doesn't work.

TinyGo's WASM target doesn't support Go's HTTP client. Instead, you use the WASI HTTP bindings directly — the same `wasi:http/outgoing-handler@0.2.0` interface that the WAVS node provides. These are generated into `gen/wasi/http/` by `wit-bindgen-go`.

```go
import (
    httphandler "github.com/your-org/component/gen/wasi/http/outgoing-handler"
    httptypes "github.com/your-org/component/gen/wasi/http/types"
    "go.bytecodealliance.org/cm"
)

func httpGet(url string) ([]byte, error) {
    scheme, authority, pathQuery, _ := parseURL(url)

    headers := httptypes.NewFields()
    req := httptypes.NewOutgoingRequest(headers)
    req.SetMethod(httptypes.MethodGet())
    req.SetScheme(cm.Some(scheme))
    req.SetAuthority(cm.Some(authority))
    req.SetPathWithQuery(cm.Some(pathQuery))

    result := httphandler.Handle(req, cm.None[httptypes.RequestOptions]())
    future := result.OK()
    future.Subscribe().Block() // synchronous: block until response

    response := future.Get().Some().OK().OK()

    // stream the body
    body := response.Consume().OK()
    stream := body.Stream().OK()

    var buf []byte
    for {
        stream.Subscribe().Block()
        chunk := stream.Read(65536)
        if chunk.IsErr() { break } // StreamError::Closed = done
        buf = append(buf, chunk.OK().Slice()...)
    }
    httptypes.IncomingBodyFinish(*body)
    return buf, nil
}
```

This is more verbose than `http.Get(url)`, but it's explicit about every step. The blocking pattern (`Subscribe().Block()`) is how WASI Preview 2 handles async I/O in a sync context — the runtime yields control while the future completes.

> **Rust developers will recognize this.** The Rust WAVS components use the exact same pattern. Go and Rust share the same WASI HTTP bindings — that's the power of the WIT interface standard.

## Encoding the Output

The output needs to be ABI-encoded for the on-chain contract to read it. The contract expects a `DataWithId` struct:

```solidity
struct DataWithId { uint64 triggerId; bytes data; }
```

Since `cgo` and most ABI libraries don't work with TinyGo in WASM, we encode manually:

```go
func encodeOutput(triggerID uint64, data []byte) []byte {
    // ABI layout: triggerId(32B) | offset(32B) | length(32B) | data(padded)
    dataLen := len(data)
    padLen := (32 - dataLen%32) % 32
    buf := make([]byte, 96+dataLen+padLen)

    binary.BigEndian.PutUint64(buf[24:32], triggerID) // right-aligned uint64
    binary.BigEndian.PutUint64(buf[56:64], 64)        // offset = 0x40
    binary.BigEndian.PutUint64(buf[88:96], uint64(dataLen))
    copy(buf[96:], data)
    return buf
}
```

It's about 15 lines of bit math. Not elegant, but correct, zero-dependency, and easy to verify.

## Building

```bash
tinygo build \
  -target=wasip2 \
  -o compiled/golang_evm_price_oracle.wasm \
  --wit-package compiled/wavs_operator_2_7_0.wasm \
  --wit-world "wavs:operator/wavs-world" \
  ./src
```

The `--wit-package` flag tells TinyGo which WIT world the component implements, so it can validate the exports and generate the correct adapter shims. Build time is under 5 seconds.

## Testing

```bash
# Bitcoin (CMC ID 1)
make wasi-exec COMPONENT_FILENAME=golang_evm_price_oracle.wasm INPUT_DATA="1"
```

Output:
```
Trigger ID: 0
Input data: 1
Computation result: {"symbol":"BTC","price":83241.50,"timestamp":"2026-03-09T15:00:00"}
```

Full end-to-end, the component is uploaded to the WAVS node, a service is deployed pointing to it, and the `addTrigger` contract function is called with the CMC ID. The WAVS operator picks up the event, runs the Go component, and submits the ABI-encoded result back on-chain.

## The Size Story

| Component | Size | Language | HTTP |
|-----------|------|----------|------|
| `golang_evm_price_oracle.wasm` | **1.3 MB** | Go (TinyGo) | Raw WASI |
| `weather_oracle.wasm` | 507 KB | Rust | Raw WASI |
| `js_evm_price_oracle.wasm` | 15 MB | TypeScript | Native fetch |

Go falls between Rust (the most compact) and TypeScript (ships a full JS engine). For most WAVS use cases — price feeds, oracles, API calls — 1.3 MB is perfectly reasonable.

## What This Means

The fact that this works at all is worth pausing on. The same WIT interface — `wavs:operator/wavs-world@2.7.0` — is implemented by Rust, Go, and TypeScript components, all producing binaries that the WAVS node executes identically. The node doesn't know or care what language compiled the WASM.

This is the promise of WASM as a universal compilation target becoming real. You pick the language that fits your team, your problem, or your existing codebase. The on-chain result is the same regardless.

The full source is in the [wavs-examples repository](https://github.com/JakeHartnell/wavs-examples) under `components/golang-evm-price-oracle/`.
