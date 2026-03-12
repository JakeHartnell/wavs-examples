# Echo

The simplest possible WAVS component — reads a trigger input and echoes it back as the response. The "Hello, World" of WAVS.

## What it does

1. Receives any string as trigger input
2. Returns it unchanged as a `WasmResponse`
3. The on-chain submit contract stores the echoed value

Use this as a starting point for new components or to verify your WAVS node and service pipeline are wired up correctly.

## How it works

```
Trigger input (string)
        │
        ▼
   [echo component]
   decode → passthrough → encode
        │
        ▼
   WasmResponse { payload: abi_encoded(string) }
```

No HTTP calls, no external dependencies. If this works, your WAVS setup is healthy.

## Running

```bash
# Deploy and register the echo service
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast

# Fire a trigger
cast send <TRIGGER_ADDR> "addTrigger(string)" "hello wavs" \
  --rpc-url http://localhost:8545 --private-key $PRIVATE_KEY

# Check the result after WAVS processes it
cast call <SUBMIT_ADDR> "getResponse(uint64)(string)" 1 --rpc-url http://localhost:8545
```

## Key files

- `src/lib.rs` — `run()` entrypoint: decode → echo → encode
- `src/trigger.rs` — trigger data decoding and output encoding
