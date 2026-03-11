# ERC-8004 Validator

A WAVS component that validates agent identities and reputation scores on-chain, implementing the [ERC-8004 Trustless Agents](https://eips.ethereum.org/EIPS/eip-8004) standard.

## What it does

1. Triggers on an on-chain validation request (agent ID + task data)
2. Checks the agent's registration in the `IdentityRegistry`
3. Queries the agent's reputation from `ReputationRegistry`
4. Returns a verdict: `isComplete` (bool) + score (0–100) + attestation hash

**This is WAVS acting as a trust oracle** — the on-chain contracts can't query reputation themselves; WAVS bridges the gap with a verifiable off-chain computation.

## How it works

```
Trigger: ValidationRequested(agentId, taskId, data)
        │
        ▼
   [erc8004-validator component]
   eth_call: IdentityRegistry.isRegistered(agentId)
   eth_call: ReputationRegistry.getScore(agentId)
        │
        ▼
   Compute verdict (registered + score >= threshold)
        │
        ▼
   WasmResponse {
     payload: abi_encoded(taskId, isComplete, score, attestation)
   }
```

## ERC-8004 Overview

ERC-8004 defines a standard for agent identity and reputation registries:
- **IdentityRegistry** — agents register a unique on-chain ID linked to their wallet
- **ReputationRegistry** — feedback accumulates into a verifiable reputation score

WAVS is the ideal evaluator: it can query multiple contracts atomically, compute the verdict deterministically, and submit a signed attestation — all without any trusted intermediary.

## Running

```bash
./scripts/deploy-erc8004.sh
```

## Key files

- `src/lib.rs` — `run()` entrypoint, validation logic
- `src/trigger.rs` — ABI decoding for `ValidationRequested` event
