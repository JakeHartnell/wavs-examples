# ERC-8183 Agentic Commerce — WAVS as Evaluator ⚡

> **WAVS acts as the trusted evaluator in an on-chain agent commerce protocol.**  
> A provider submits work. WAVS fetches the deliverable, verifies it, and settles the escrow — autonomously, cryptographically.

---

## What This Demonstrates

[ERC-8183](https://eips.ethereum.org/EIPS/eip-8183) is a minimal job escrow protocol for agentic commerce. A **client** posts a job and funds it with tokens. A **provider** does the work and submits a deliverable. An **evaluator** decides if the work was done correctly — releasing payment or refunding the client.

**WAVS is the evaluator.** When a provider submits, WAVS:
1. Watches for the `JobSubmitted` on-chain event
2. Fetches the URL from the job description via eth_call
3. Computes `keccak256` of the HTTP response
4. Compares against the provider's `deliverable` hash
5. Calls `complete()` (pay provider) or `reject()` (refund client) on-chain — signed by the WAVS operator set

No human in the loop. No trusted third party. Just verifiable compute settling real money.

---

## Architecture

```
Client                    Provider              WAVS Operator
  │                          │                      │
  ├─ createJob(url, ACE) ──► AgenticCommerce        │
  ├─ fund(jobId, tokens) ──► [escrow locked]         │
  │                          │                      │
  │                    submit(jobId, hash) ──────────┤
  │                          │              JobSubmitted event
  │                          │                      │
  │                          │              1. eth_call → get url
  │                          │              2. HTTP GET url
  │                          │              3. keccak256(response)
  │                          │              4. compare vs deliverable
  │                          │                      │
  │                          │              AgenticCommerceEvaluator
  │                          │              handleSignedEnvelope()
  │                          │                      │
  │                ◄── complete(jobId) / reject(jobId) ──────────────┘
  │                [provider paid OR client refunded]
  │
  └── ReputationHook → ERC-8004 ReputationRegistry (+100 / -100)
```

### Contracts

| Contract | Role |
|---|---|
| `AgenticCommerce` | ERC-8183 implementation — job escrow state machine |
| `AgenticCommerceEvaluator` | WAVS `IWavsServiceHandler` — the on-chain evaluator |
| `ReputationHook` | ERC-8183 hook — writes ERC-8004 reputation after settlement |
| `MockERC20` | Payment token (tUSDC) for local testing |
| `IdentityRegistry` | ERC-8004 identity registry |
| `ReputationRegistry` | ERC-8004 reputation registry |

### WAVS Component

**`agentic-commerce-evaluator`** (`components/agentic-commerce-evaluator/`)

- Trigger: `JobSubmitted(uint256 jobId, address provider, bytes32 deliverable)`
- Logic: eth_call → HTTP GET → keccak256 compare → encode verdict
- Output: `abi.encode(jobId, isComplete, attestation)` → `AgenticCommerceEvaluator`
- WASI: raw bindings only (no wstd, fully WASI 0.2.3 compatible ✅)

---

## Job Lifecycle

```
Open ──► Funded ──► Submitted ──► Completed  (provider paid)
  │         │           │
  └─Reject  └─Reject  └─Reject / Expired  (client refunded)
```

State transitions:
- **Open** → `createJob()` — client sets provider, evaluator, expiry, description (URL), optional hook
- **Funded** → `fund(jobId, budget)` — tokens pulled into escrow
- **Submitted** → `submit(jobId, deliverable)` — provider signals work done; fires `JobSubmitted` event
- **Completed** → `complete(jobId, reason)` — evaluator only; releases escrow to provider
- **Rejected** → `reject(jobId, reason)` — evaluator or client; refunds client

---

## Running the Demo

### Prerequisites

- WAVS node running at `http://localhost:8041`
- Anvil running at `http://localhost:8545`  
- `wavs-examples` deployed (need `SERVICE_MANAGER_ADDR`)

```bash
# From the wavs-examples root
SERVICE_MANAGER_ADDR=0x... ./scripts/demo-agentic-commerce.sh
```

The script:
1. Deploys all contracts (MockERC20, AgenticCommerce, AgenticCommerceEvaluator, ReputationHook, ERC-8004 registries)
2. Registers the provider as an ERC-8004 agent
3. Builds and uploads the WAVS component
4. Registers the WAVS service (watching `AgenticCommerce` for `JobSubmitted`)
5. Creates a job with `https://httpbin.org/json` as the deliverable URL
6. Funds the job (100 tUSDC in escrow)
7. Provider submits `keccak256(GET https://httpbin.org/json)` as deliverable
8. WAVS fetches the URL, verifies the hash, calls `complete()` on-chain
9. Provider receives payment; ERC-8004 reputation updated (+100)

Expected output:
```
[OK]  JOB COMPLETED! ⚡ ERC-8183 settlement verified
      AgenticCommerce:          0x...
      AgenticCommerceEvaluator: 0x...
      Job ID:                   1
      Provider paid:            100000000 tUSDC (raw)
      ERC-8004 feedback count:  1
```

---

## ERC-8004 Integration

This example also demonstrates **ERC-8004 reputation** integration via the hook system:

- Provider registers in the `IdentityRegistry` → gets `agentId`
- `ReputationHook` is set on job creation
- After `complete()` → `ReputationRegistry.giveFeedback(agentId, +100, "acp:complete", "wavs")`
- After `reject()` → `giveFeedback(agentId, -100, "acp:reject", "wavs")`

The official ERC-8004 registries are deployed on mainnet/Sepolia — this demo deploys local non-upgradeable versions for Anvil.

---

## The Full Trust Stack

This example shows how three draft ERCs compose into a complete trust stack for autonomous agents:

| Standard | Role |
|---|---|
| **ERC-8004** | Agent identity + reputation registry |
| **ERC-8183** | On-chain job escrow + settlement protocol |
| **WAVS** | Verifiable compute layer — the evaluator |

WAVS is uniquely positioned as the ERC-8183 evaluator because it provides:
- **Determinism** — all operators run the same logic on the same data
- **Crypto-economic security** — operator set with stake
- **On-chain attestation** — signed result committed to the chain
- **Arbitrary compute** — fetch URLs, call APIs, run ML inference, verify ZK proofs

Any off-chain work a provider could do, WAVS can verify.

---

## Related Standards

- [ERC-8183](https://eips.ethereum.org/EIPS/eip-8183) — Agentic Commerce Protocol
- [ERC-8004](https://eips.ethereum.org/EIPS/eip-8004) — Trustless Agents (identity + reputation)
- [ERC-8128](https://github.com/slice-so/ERCs) — HTTP Message Signatures with Ethereum
