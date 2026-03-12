# LLM Oracle

A WAVS component that runs LLM inference and submits the result on-chain. Any prompt in, verifiable response on-chain out.

## What it does

1. Receives a text prompt as trigger input
2. Calls a configured LLM (Ollama or any OpenAI-compatible API)
3. Returns the response + `keccak256(response)` as on-chain attestation

**Use cases:**
- On-chain AI decisions with verifiable provenance
- Sentiment analysis, summarization, classification
- Agent task completion with auditable outputs

## How it works

```
Trigger input: "Summarize the state of ZK proofs in 2026"
        │
        ▼
   [llm-oracle component]
   POST http://localhost:11434/api/chat   (Ollama)
        │
        ▼
   LLM response text
        │
        ▼
   WasmResponse {
     payload: abi_encoded(triggerId, response, keccak256(response))
   }
```

The `responseHash` lets anyone verify the exact response that was attested on-chain.

## Config

Set via WAVS service config variables:

| Variable | Default | Description |
|---|---|---|
| `llm_api_url` | `http://host.docker.internal:11434` | Ollama or OpenAI-compatible base URL |
| `llm_model` | `llama3.2` | Model name |
| `llm_api_key` | *(none)* | API key (optional, for hosted providers) |

## Running

```bash
./scripts/deploy-llm-oracle.sh
```

## Key files

- `src/lib.rs` — `run()` entrypoint, LLM call, response hashing
- `src/trigger.rs` — trigger decoding and output encoding
