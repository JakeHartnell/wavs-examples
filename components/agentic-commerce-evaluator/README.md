# Agentic Commerce Evaluator

A WAVS component that acts as the trusted evaluator in the [ERC-8183 Agentic Commerce](https://eips.ethereum.org/EIPS/eip-8183) protocol. WAVS watches for job submissions, fetches the provider's deliverable, computes a hash, and settles payment — all without any human intermediary.

## What it does

1. Triggers on `JobSubmitted(jobId, provider, deliverable)` from `AgenticCommerce.sol`
2. Reads the job's URL (the task description) via `eth_call`
3. Fetches the content at that URL
4. Computes `keccak256(content)` and compares to the provider's claimed `deliverable`
5. Returns verdict: `isComplete` (bool) + attestation hash

The on-chain `AgenticCommerceEvaluator` contract receives the WAVS-signed result and calls either `complete()` (pay provider) or `reject()` (refund client).

## How it works

```
JobSubmitted event
        │
        ▼
   [agentic-commerce-evaluator]
   eth_call: getJobDescription(jobId) → URL
   GET <url>
   keccak256(body) == deliverable?
        │
     yes │ no
        ▼   ▼
   complete() reject()
   (pay)   (refund)
```

This is **deterministic verification** — every WAVS operator fetches the same URL, computes the same hash, reaches the same verdict. No subjectivity, no trust required.

For LLM-based qualitative evaluation, see [`llm-commerce-evaluator`](../llm-commerce-evaluator/).

## Running

```bash
RPC_URL=http://localhost:8545 WAVS_URL=http://localhost:8041 \
  bash scripts/demo-agentic-commerce.sh
```

## Key files

- `src/lib.rs` — `run()` entrypoint: decode → fetch → hash → compare → encode
- `src/trigger.rs` — `JobSubmitted` decoding, `eth_call` for job description, verdict encoding
- `src/http.rs` — raw WASI HTTP helpers (no `wstd` dependency)

## Related contracts

- `src/contracts/agentic-commerce/AgenticCommerce.sol` — job escrow + lifecycle
- `src/contracts/agentic-commerce/AgenticCommerceEvaluator.sol` — WAVS submit handler
