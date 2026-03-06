# 01 — Echo

The simplest possible WAVS service: post a string on-chain, get it echoed back verifiably.

## What it does

1. Call `addTrigger("hello world")` on the `SimpleTrigger` contract
2. The WAVS component picks up the event, echoes the string as JSON, and signs the result
3. The signed result lands on the `SimpleSubmit` contract, readable by anyone

That's the full WAVS loop — trigger → WASM → aggregator → on-chain — in its most minimal form.

## Why it matters (for agents)

This is the "hello world" of verifiable agent outputs. An agent calling `addTrigger` with structured data gets back a cryptographically signed, on-chain result. It proves the computation ran. It's auditable forever.

## Prerequisites

- Local WAVS node running (`task start-all-local`)
- Anvil running on `localhost:8545`

## Run it

```bash
# 1. Build the contracts
task build:forge

# 2. Build the WASM component
task build:wasi WASI_BUILD_DIR=components/echo

# 3. Deploy contracts + service
task deploy

# 4. Trigger it
cast send $TRIGGER_CONTRACT "addTrigger(string)" "hello from WAVS" \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --rpc-url http://localhost:8545

# 5. Read the result
cast call $SUBMIT_CONTRACT "getData(uint64)(bytes)" 1 \
  --rpc-url http://localhost:8545 | cast --to-utf8
```

## How it works

```
addTrigger("hello")
    → NewTrigger event emitted
    → WAVS operator detects event
    → echo component runs: decode string → JSON wrap → encode
    → operator signs result
    → aggregator submits to SimpleSubmit
    → getData(triggerId) returns {"echo":"hello"}
```

## Component

See [`components/echo/`](../../../components/echo/) in the repo root.
