# LLM Commerce Evaluator

A WAVS component that acts as an AI-powered evaluator in the [ERC-8183 Agentic Commerce](https://eips.ethereum.org/EIPS/eip-8183) protocol. Instead of deterministic hash comparison, this evaluator uses an LLM to judge whether a provider's work actually satisfies the job requirements.

This is **verifiable AI judgment** — the LLM runs inside WASM on every WAVS operator, producing identical results at `temperature=0`, with the verdict signed and settled on-chain.

## What it does

1. Triggers on `JobSubmitted(jobId, provider, deliverable)` from `AgenticCommerce.sol`
2. Reads the original task prompt and the worker's result URI via `eth_call`
3. Fetches the worker's published output
4. Calls an LLM (Ollama) with a structured prompt:
   - *"Does this output satisfy the task requirements? Score 0–100, approve if ≥ 70."*
5. Returns: `approved` (bool) + `score` (0–100) + `reasoning` (string)
6. `keccak256(reasoning)` is stored on-chain as a verifiable attestation

## How it works

```
JobSubmitted event
        │
        ▼
   [llm-commerce-evaluator]
   eth_call: getJobDescription(jobId) → task prompt
   eth_call: getJobResultUri(jobId)   → paste.rs URL
   GET <result_uri> → worker's output
        │
        ▼
   LLM: "Does this satisfy the requirements?"
   → { approved: true, score: 87, reasoning: "..." }
        │
     yes │ no
        ▼   ▼
   complete() reject()
   (pay)   (refund)
```

The LLM verdict and reasoning are preserved in WAVS component logs (`GET /dev/logs/{service_id}`), giving a full audit trail of every evaluation.

## Config

| WAVS env var | Default | Description |
|---|---|---|
| `WAVS_ENV_OLLAMA_API_URL` | `http://localhost:11434` | Ollama endpoint |
| `WAVS_ENV_LLM_MODEL` | `llama3.2` | Model to use |
| `WAVS_ENV_LLM_SYSTEM_PROMPT` | *(built-in)* | Override evaluation criteria |

**Requires Ollama running locally** with your chosen model pulled:
```bash
ollama pull llama3.2
```

## Why temperature=0 matters

Multiple WAVS operators must agree on the result. With `temperature=0`, the same model + same prompt + same input always produces the same output — consensus is guaranteed without any coordination overhead.

## Key files

- `src/lib.rs` — `run()` entrypoint, orchestrates fetch → LLM → encode
- `src/llm.rs` — structured LLM call via `wavs-llm`, returns `JobEvaluation`
- `src/trigger.rs` — `JobSubmitted` decoding, dual `eth_call`, verdict encoding
- `src/http.rs` — raw WASI HTTP helpers

## Related components

- [`agentic-commerce-evaluator`](../agentic-commerce-evaluator/) — deterministic hash-based evaluator (no LLM required)
- [`agentic-commerce-worker`](../agentic-commerce-worker/) — the LLM worker that produces the deliverable this evaluator judges
