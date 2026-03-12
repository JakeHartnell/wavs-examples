# Weather Oracle

A WAVS component that fetches live weather data and submits it on-chain. Demonstrates external HTTP calls from inside WASM with verifiable on-chain results.

## What it does

1. Receives a city name as trigger input
2. Fetches current weather from [wttr.in](https://wttr.in) (no API key needed)
3. Returns temperature, condition, and city as ABI-encoded data
4. The on-chain contract stores the weather report

**Example output:**
```
London: 9.8°C, Partly cloudy
```

## How it works

```
Trigger input: "London"
        │
        ▼
   [weather-oracle component]
   GET https://wttr.in/London?format=j1
        │
        ▼
   Parse JSON → extract temp + condition
        │
        ▼
   WasmResponse { payload: abi_encoded(city, temp, condition) }
```

HTTP is made via raw WASI interfaces (no `wstd` / `wavs-wasi-utils`) — compatible with WAVS node WASI 0.2.x.

## Config

No configuration required. The city name comes from the trigger input.

## Running

```bash
./scripts/deploy-weather.sh
```

Or manually:

```bash
# Fire a trigger for London
cast send <TRIGGER_ADDR> "addTrigger(string)" "London" \
  --rpc-url http://localhost:8545 --private-key $PRIVATE_KEY

# Read result after WAVS processes it
cast call <SUBMIT_ADDR> "getWeather(uint64)" 1 --rpc-url http://localhost:8545
```

## Key files

- `src/lib.rs` — `run()` entrypoint
- `src/trigger.rs` — trigger decoding and output encoding
- `src/http.rs` — raw WASI HTTP helpers
