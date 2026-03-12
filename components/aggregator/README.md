# Aggregator

The shared WAVS aggregator component used by all ERC-8183 Agentic Commerce services. Not a standalone example — this is infrastructure that runs on the aggregator side of the WAVS pipeline.

## What it does

The aggregator runs after the operator component and is responsible for routing the signed result to the correct on-chain handler. It reads the target contract address from the service's `config` map (keyed by chain ID) and submits the payload via `handleSignedEnvelope`.

```
Operator WasmResponse (signed by N operators)
        │
        ▼
   [aggregator component]
   Read workflow.submit.config → { "evm:31337": "0xACE..." }
        │
        ▼
   AggregatorAction::Submit → EvmSubmitAction { chain, address }
        │
        ▼
   AgenticCommerceEvaluator.handleSignedEnvelope(envelope, sigs)
```

## How it works

The aggregator reads the submit config map to find which contract to call on which chain. A single aggregator component handles all Agentic Commerce services — the target contract is parameterized via config, not hardcoded.

Multi-chain support is built in: if the config has entries for multiple chains (e.g. `evm:31337` and `evm:1`), the aggregator submits to all of them.

## Usage

This component is referenced by service manifests via its WASM digest. You don't deploy it directly — it's uploaded once and reused across all services that need EVM submission:

```json
"submit": {
  "aggregator": {
    "component": { "source": { "digest": "<aggregator-digest>" } },
    "config": { "evm:31337": "<submit-handler-address>" }
  }
}
```

## Key files

- `src/lib.rs` — `process_input()`, `handle_submit_callback()`
