# 01 — Weather Oracle

A WAVS component that fetches current weather data and commits it on-chain. No API key required — uses the free [Open-Meteo](https://open-meteo.com/) API.

## What it does

1. Call `addTrigger("London")` (or `"48.8566,2.3522"` for lat/lon) on the `SimpleTrigger` contract
2. The WAVS component geocodes the location (if needed) and fetches current weather from Open-Meteo
3. The signed result lands on `SimpleSubmit` — readable by anyone, verifiably produced

**Output fields:**
```json
{
  "location": "London",
  "latitude": 51.5085,
  "longitude": -0.1257,
  "temperature_c": 14.2,
  "humidity_pct": 72,
  "wind_speed_kmh": 18.5,
  "weather_code": 3,
  "description": "Overcast",
  "timestamp": "2026-03-07T12:00"
}
```

## Why it matters (for agents)

Weather data is a surprisingly high-value oracle primitive. Parametric insurance payouts, agricultural derivatives, event-based smart contracts — all need trustworthy feeds. This component shows the full pattern:

```
off-chain API fetch → WAVS multi-operator verification → on-chain signed fact
```

An agent querying weather doesn't need to trust any single data source. Multiple WAVS operators independently fetch and verify. The on-chain result comes with cryptographic proof.

## Prerequisites

- Local WAVS node + Anvil running (`task start-all-local`)
- `cargo-component`, `forge`, `cast` in PATH

## Run it

```bash
# From the repo root
./scripts/deploy-weather.sh
```

Or step by step:

```bash
# 1. Build the WASM component
cargo component build --release -p weather-oracle --target wasm32-wasip1

# 2. Deploy contracts + register service
./scripts/deploy-weather.sh

# 3. Fire a trigger (city name or lat,lon)
cast send $TRIGGER_ADDR "addTrigger(string)" "Tokyo" \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --rpc-url http://localhost:8545

# 4. Read the result (after ~10-20s for WAVS to process)
cast call $SUBMIT_ADDR "getData(uint64)(bytes)" 1 \
  --rpc-url http://localhost:8545 | python3 -c "import sys,json; print(json.dumps(json.loads(bytes.fromhex(input()[2:])), indent=2))"
```

## Input formats

| Format | Example |
|--------|---------|
| City name | `"London"` |
| City + country | `"Paris"` |
| Lat/lon | `"40.7128,-74.0060"` |

## How it works

```
addTrigger("London")
    → NewTrigger event emitted on SimpleTrigger
    → WAVS operator detects event
    → weather-oracle component:
        1. ABI-decode the string input
        2. If city name: geocode via Open-Meteo geocoding API
        3. Fetch current weather from Open-Meteo forecast API
        4. Encode as JSON bytes
    → operator signs result
    → aggregator submits to SimpleSubmit
    → getData(triggerId) returns JSON weather data
```

## Component

See [`components/weather-oracle/`](../../../components/weather-oracle/) for the Rust/WASM source.

## Contracts used

This example reuses the shared infrastructure contracts:
- **SimpleTrigger** — `addTrigger(string)` emits `NewTrigger` event
- **SimpleServiceManager** — validates operator signatures
- **SimpleSubmit** — stores verified output, exposes `getData(triggerId)`

No custom Solidity needed — the generic trigger/submit pattern handles any JSON output.
