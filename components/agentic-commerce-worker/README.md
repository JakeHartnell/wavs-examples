# Agentic Commerce Worker

A WAVS component that acts as an autonomous AI provider in the [ERC-8183 Agentic Commerce](https://eips.ethereum.org/EIPS/eip-8183) protocol. When a job is funded, this component picks it up, completes the task using an LLM, publishes the output, and submits the deliverable — with no human involvement.

Pair this with [`llm-commerce-evaluator`](../llm-commerce-evaluator/) for a fully autonomous agent-to-agent commerce loop: a client creates a job, the worker fulfills it, the evaluator judges it, and payment settles on-chain.

## What it does

1. Triggers on `JobFunded(jobId, budget)` from `AgenticCommerce.sol`
2. Reads the task prompt from `job.description` via `eth_call`
3. Calls an LLM to complete the task (`temperature=0` for determinism)
4. Publishes the output to [paste.rs](https://paste.rs) — gets a public URL back
5. Computes `keccak256(llm_output)` as the deliverable hash
6. Returns `(jobId, deliverable, resultUri)` — submitted via `AgenticCommerceWorker.sol`

The on-chain `AgenticCommerceWorker` contract receives the WAVS-signed result and calls `AgenticCommerce.submitWithResult(jobId, deliverable, resultUri)`.

## The full autonomous loop

```
[Client] createJob(provider=ACW, description="Write an explanation of WAVS...")
         fund(jobId, 100 tUSDC)
              │ JobFunded event
              ▼
   [Worker WAVS component]  ← this component
   Reads task → calls LLM → publishes to paste.rs
   Submits: keccak256(output) + paste URL
              │ JobSubmitted event
              ▼
   [LLM Evaluator WAVS component]
   Fetches paste URL → LLM judges quality
   Approves or rejects
              │
              ▼
   Provider paid / Client refunded
```

No human acts as the provider. The worker is the provider.

## Config

| WAVS env var | Default | Description |
|---|---|---|
| `WAVS_ENV_OLLAMA_API_URL` | `http://localhost:11434` | Ollama endpoint |
| `WAVS_ENV_LLM_MODEL` | `llama3.2` | Model to use |
| `WAVS_ENV_WORKER_SYSTEM_PROMPT` | *(built-in)* | Override worker instructions |

**Requires Ollama running locally:**
```bash
ollama pull llama3.2
```

## Why temperature=0 matters

Multiple WAVS operators run this component in parallel and must agree on the same output to reach quorum. `temperature=0` ensures every operator's LLM call produces identical text — deterministic consensus without coordination.

## Key files

- `src/lib.rs` — `run()` entrypoint: decode → LLM → publish → encode
- `src/llm.rs` — LLM task completion via `wavs-llm`
- `src/trigger.rs` — `JobFunded` decoding, `eth_call` for description, `WorkerResult` encoding
- `src/http.rs` — raw WASI HTTP helpers + `publish_paste()` for paste.rs

## Related contracts

- `src/contracts/agentic-commerce/AgenticCommerce.sol` — job escrow + `submitWithResult()`
- `src/contracts/agentic-commerce/AgenticCommerceWorker.sol` — WAVS submit handler (the `provider`)

## Related components

- [`llm-commerce-evaluator`](../llm-commerce-evaluator/) — the evaluator that judges this worker's output
- [`agentic-commerce-evaluator`](../agentic-commerce-evaluator/) — simpler hash-based evaluator
