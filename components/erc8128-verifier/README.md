# ERC-8128 Verifier

A WAVS component that verifies [RFC 9421 HTTP Message Signatures](https://www.rfc-editor.org/rfc/rfc9421) on-chain, implementing the [ERC-8128](https://eips.ethereum.org/EIPS/eip-8128) standard.

## What it does

1. Receives an HTTP request with a `Signature` and `Signature-Input` header
2. Reconstructs the signature base string per RFC 9421
3. Recovers the Ethereum address using `ecrecover` (secp256k1 in WASM)
4. Returns: `verified` (bool) + recovered address + signature hash

**Use case:** Prove that a specific Ethereum address made a specific HTTP request — without trusting any intermediary. AI agents can sign their API calls; WAVS verifies the signatures on-chain.

## How it works

```
Trigger: HTTP request bytes (method, URL, headers, body)
        │
        ▼
   [erc8128-verifier component]
   Parse Signature-Input header → component list
   Reconstruct signature base string
   secp256k1 ecrecover in WASM
        │
        ▼
   WasmResponse {
     payload: abi_encoded(verified, recoveredAddress, sigHash)
   }
```

## ERC-8128 Overview

ERC-8128 bridges HTTP and Ethereum: an agent signs HTTP requests with their Ethereum private key using standard RFC 9421 message signatures. Any observer can verify *who* made *what* request, without the request having gone through an on-chain transaction.

This is foundational for:
- Verifiable AI agent API calls
- Attribution of off-chain actions to on-chain identities  
- Audit trails for agentic systems

See [`ERC8128_RESEARCH.md`](../../ERC8128_RESEARCH.md) for the full design write-up.

## Running

```bash
# Test with a raw signed HTTP request
cargo test -- --nocapture
```

## Key files

- `src/lib.rs` — `run()` entrypoint, signature verification flow
- `src/trigger.rs` — RFC 9421 signature base reconstruction
