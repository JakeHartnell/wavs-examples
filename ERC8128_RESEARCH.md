# ERC-8128 + WAVS: Verifiable HTTP Authentication for Agents

*Research post — basis for a WAVS feature proposal: native ERC-8128 trigger support*

---

## What is ERC-8128?

[ERC-8128](https://github.com/slice-so/ERCs/blob/d9c6f41183008285a0e9f1af1d2aeac72e7a8fdc/ERCS/erc-8128.md) is a draft standard (authors: slice.so team) that defines **Ethereum-authenticated HTTP requests** using [RFC 9421 HTTP Message Signatures](https://www.rfc-editor.org/rfc/rfc9421).

The core idea: instead of bearer tokens, cookies, or JWTs, an HTTP client signs the request itself — method, path, body digest, headers — using their Ethereum private key (`personal_sign` / EIP-191). The server verifies the signature and recovers the Ethereum address. No credential issuance. No shared secrets. No session state.

```
Client                                       Server / WAVS
  │                                              │
  │  POST /orders HTTP/1.1                       │
  │  Signature-Input: eth=("@method"             │
  │    "@authority" "@path");                    │
  │    keyid="eip8128:1:0xDEAD...";             │
  │    created=1618884475;expires=1618884775;    │
  │    nonce="abc123"                            │
  │  Signature: eth=:base64(sig):               │
  │ ──────────────────────────────────────────► │
  │                                              │  Parse Signature-Input
  │                                              │  Reconstruct signature base (RFC 9421)
  │                                              │  keccak256(ERC-191 prefix + base)
  │                                              │  ecrecover → Ethereum address
  │                                              │  Compare to keyid address
  │ ◄────────────────────────────────────────── │
  │  200 OK  (or 401 if invalid)                │
```

### Signature Structure (RFC 9421 + ERC-8128)

The **signature base** is constructed by serializing the covered components:

```
"@method": POST
"@authority": api.example.com
"@path": /orders
"@signature-params": ("@method" "@authority" "@path");keyid="eip8128:1:0x...";created=...;expires=...;nonce="..."
```

Each line is `"<component-id>": <value>`, joined by `\n`, no trailing newline. The `@signature-params` line is always last.

The signer then computes:
```
H = keccak256("\x19Ethereum Signed Message:\n" + decimal(len(M)) + M)
signature = secp256k1_sign(H, private_key)
```

And the verifier recovers the address via `ecrecover(H, signature)` and compares against the `keyid`.

### Security Dimensions

ERC-8128 defines two independent security axes:

| Dimension | Options | Trade-off |
|---|---|---|
| **Request Binding** | Request-Bound (method+path+body) vs Class-Bound (subset) | Integrity vs. flexibility |
| **Replay Protection** | Non-Replayable (requires nonce) vs Replayable | Security vs. performance |

Compliant verifiers MUST accept the strongest posture (Request-Bound + Non-Replayable). Weaker modes are optional.

### Relation to ERC-8004

ERC-8128 sits alongside [ERC-8004](https://eips.ethereum.org/EIPS/eip-8004) (AI Agent Identity + Validation) in the emerging agent authentication stack. ERC-8004 handles *who is this agent* (identity) and *is this agent trustworthy* (validation score). ERC-8128 handles *proving an Ethereum account made this specific HTTP request* at the transport layer.

Together they form a complete agent authentication story:
- ERC-8004: "This agent has identity `0xDEAD...` and a validation score of 95/100"
- ERC-8128: "And I can prove that `0xDEAD...` made THIS specific HTTP request, not a replay"

---

## What We Built: A WAVS PoC

We implemented `components/erc8128-verifier/` — a WAVS WASM component that:

1. Receives an HTTP request payload via a **raw WAVS trigger** (JSON)
2. Parses `Signature-Input` and `Signature` headers per RFC 9421
3. Reconstructs the signature base from covered component values
4. Applies ERC-191 `personal_sign` hash: `keccak256("\x19Ethereum Signed Message:\n" + len + M)`
5. Recovers the Ethereum signer address via secp256k1 `ecrecover`
6. Returns the result as a `WasmResponse` JSON (no on-chain submission needed for this PoC)

The component is ~250 LOC of pure Rust, WASM-safe (no `wstd`, no `wasi:random`, uses `k256` for pure-Rust ecrecover).

### Example Trigger Input

```json
{
  "signature_input": "eth=(\"@method\" \"@authority\" \"@path\");keyid=\"eip8128:1:0xDEAD...\";created=1618884475;expires=1618884775;nonce=\"abc123\"",
  "signature": "eth=:base64-encoded-65-byte-sig:",
  "components": {
    "@method": "POST",
    "@authority": "api.example.com",
    "@path": "/orders"
  }
}
```

### Example Output

```json
{
  "valid": true,
  "recovered_address": "0xdead...",
  "expected_address": "0xdead...",
  "chain_id": 1,
  "keyid": "eip8128:1:0xdead...",
  "covered_components": ["@method", "@authority", "@path"],
  "signature_base": "\"@method\": POST\n\"@authority\": api.example.com\n\"@path\": /orders\n\"@signature-params\": ...",
  "note": "✅ signature valid: address recovered"
}
```

---

## The Real Opportunity: Native ERC-8128 Triggers in WAVS

The PoC demonstrates the verification logic. But the bigger opportunity is making **ERC-8128 a first-class WAVS trigger type** — so that AI agents and API clients can trigger WAVS workflows by simply making authenticated HTTP requests, without needing to submit on-chain transactions at all.

This section is a spec sketch for a WAVS feature proposal.

---

## Proposed Feature: `http_message_signature` Trigger

### Overview

WAVS would expose a new endpoint (per-service or shared+routed) that:
1. Receives an HTTP request
2. Verifies the ERC-8128 signature **before** queuing the trigger
3. Passes a verified trigger event to the operator component with the recovered signer address + request data

The key benefit: **zero on-chain cost to trigger**. Any Ethereum account — including an AI agent — can invoke a WAVS workflow by signing an HTTP request with their private key. No gas. No transaction. Just an HTTP call.

---

### Design Questions (open issues for the spec)

#### 1. Endpoint Architecture

**Option A: Per-service HTTP endpoint**
```
POST https://wavs-node.example.com/services/{service_id}/trigger
Signature-Input: eth=...
Signature: eth=...
```
- Simple routing: service_id in path → unambiguous dispatch
- No per-service DNS config needed
- Works well for programmatic agent-to-agent calls

**Option B: Arbitrary upstream URL, WAVS as verifying proxy**
- The "Signature-Input Authority" can be any domain
- WAVS verifies the signature then forwards internally
- More flexible for existing API patterns

**Recommendation:** Start with Option A (per-service endpoint). Option B is a proxy model that can be layered on top later.

---

#### 2. Verification Timing

Verification MUST happen at the WAVS node before the trigger is queued. If the signature is invalid, WAVS returns `401 Unauthorized` immediately — the operator component never runs. This is important:
- Prevents spam from unauthenticated callers
- The component can trust `trigger.signer_address` is cryptographically verified
- The component doesn't need to reimplement signature verification

---

#### 3. Trigger Data Schema (WIT)

What should the operator component receive? A new `TriggerData` variant:

```wit
// In wavs-types.wit (proposed addition)
variant trigger-data {
    // ... existing variants ...
    erc8128-request(erc8128-trigger),
}

record erc8128-trigger {
    // Verified signer (from ecrecover — already authenticated by the node)
    signer-address: string,         // "0x..." lowercase
    chain-id: u64,
    keyid: string,                  // "eip8128:<chain-id>:<address>"
    
    // Signature metadata
    created: u64,
    expires: u64,
    nonce: option<string>,
    binding: request-binding,
    
    // Request data (covered + uncovered components)
    method: string,
    authority: string,
    path: string,
    query: option<string>,
    
    // Request body (if content-digest was covered)
    body: option<list<u8>>,
    content-digest: option<string>,
    
    // Additional headers (non-sensitive, application-defined)
    headers: list<tuple<string, string>>,
    
    // Application-level payload (e.g., JSON body parsed from body)
    // The component can decode this from `body` itself
}

enum request-binding {
    request-bound,
    class-bound,
}
```

---

#### 4. Replay Protection (Nonce Management)

Non-Replayable is the ERC-8128 baseline. The WAVS node needs a nonce store:

- Track `(keyid, nonce)` pairs within the signature validity window `expires - created`
- Reject a request if `(keyid, nonce)` was already seen
- Prune nonces after they expire

**Options:**
- **In-memory nonce store**: Simple, fast, lost on restart. Acceptable for dev; insufficient for production (restart attack).
- **Persistent nonce store**: WAVS already has a data directory (`~/.wavs/data`). A simple SQLite or flat-file store would work. Consistent across restarts.
- **On-chain nonce validation**: Delegate to a contract. Expensive, slow. Skip for now.

**Recommendation:** Persistent nonce store with a TTL-based pruning job. The `expires` field bounds the required retention window.

---

#### 5. ERC-1271 (Smart Contract Account) Support

ERC-8128 supports SCAs via [ERC-1271](https://eips.ethereum.org/EIPS/eip-1271). Instead of `ecrecover`, the verifier calls `isValidSignature(bytes32 hash, bytes sig)` on the contract at `address` on `chain-id`.

This is significantly more complex:
- Requires an RPC call to the specified chain
- Chain must be configured in WAVS
- Adds latency (network round-trip per request)
- SCAs can have dynamic validation logic (e.g., multisig, session keys, spending limits)

**Recommendation:** EOA-only for v1. ERC-1271 support in a follow-up. The `keyid` format includes `chain-id` so the information is there for future use. The node can detect SCA vs EOA by checking if the recovered address matches the keyid — if not, attempt ERC-1271 if configured.

---

#### 6. Security Policy at the Node Level

WAVS node operators should be able to configure per-service policy:

```toml
[services.my-service.erc8128_policy]
# Minimum binding level required
require_binding = "request-bound"  # or "class-bound"

# Whether to accept replayable signatures
allow_replayable = false

# Maximum validity window (seconds)
max_validity_seconds = 300

# Clock skew tolerance (seconds)
clock_skew_seconds = 5

# Whether to attempt ERC-1271 for non-recovering addresses
erc1271_enabled = false
erc1271_chains = ["evm:1", "evm:8453"]
```

---

#### 7. Service Registration

How does a service opt into ERC-8128 triggers? Two paths:

**Path A: Service JSON (existing mechanism)**
```json
{
  "name": "my-agent-service",
  "workflows": {
    "default": {
      "trigger": {
        "http_message_signature": {
          "policy": {
            "require_binding": "request-bound",
            "allow_replayable": false,
            "max_validity_seconds": 300
          }
        }
      },
      "component": { ... }
    }
  }
}
```

**Path B: On-chain trigger (hybrid)**
The agent makes an on-chain call to a `WAVSTriggerRegistry` contract that emits an `ERC8128TriggerRegistered(address signer, bytes config)` event. WAVS watches for that event, creates the service binding, and starts accepting ERC-8128 requests for that signer. This is more complex but enables fully on-chain service discovery and permissioning.

**Recommendation:** Path A for v1.

---

#### 8. Response to the Caller

Unlike on-chain triggers (fire-and-forget), HTTP triggers have a synchronous response expectation. Options:

**Option A: Async (accepted/rejected immediately)**
```
HTTP 202 Accepted
{ "trigger_id": "abc123", "status": "queued" }
```
The caller polls a status endpoint or uses a webhook. Simple for the node, but less ergonomic for callers.

**Option B: Sync with timeout**
WAVS holds the HTTP connection open for up to N seconds waiting for the component to complete, then returns the result. Ergonomic for callers, but ties up connection resources and complicates WAVS internals.

**Option C: SSE / WebSocket streaming**
WAVS sends back a stream of progress events. Complex to implement.

**Recommendation:** Option A for v1. Async with a status endpoint is the most robust. Agents can poll or subscribe. The synchronous model can be layered on top via a gateway/proxy.

---

### Implementation Complexity Assessment

| Component | Complexity | Notes |
|---|---|---|
| RFC 9421 header parsing | Low | Straightforward string parsing (our PoC proves this) |
| Signature base reconstruction | Low | Deterministic from components |
| ERC-191 + ecrecover | Low | Pure Rust, WASM-proven |
| HTTP endpoint (per-service) | Medium | New HTTP server surface for WAVS |
| Nonce store (persistent) | Medium | Add SQLite/flat-file store to WAVS data dir |
| WIT type extension | Medium | New `erc8128-trigger` variant in wavs-types.wit |
| Service JSON schema | Low | Add new trigger type definition |
| ERC-1271 SCA support | High | RPC calls, chain config, error handling |
| Replayable signatures | Medium | Early invalidation mechanisms required |
| Sync response mode | High | Connection pooling, timeout management |

**Suggested v1 scope:**
- EOA-only (no ERC-1271)
- Non-Replayable only (enforce nonce)
- Request-Bound required
- Async response (202 + status endpoint)
- Per-service HTTP endpoint
- Persistent in-process nonce store (flat-file or SQLite)

---

### Why This Matters for WAVS

WAVS is already in a unique position as verifiable compute infrastructure for agents (see ERC-8004 work). Adding ERC-8128 native triggers closes the loop on the agent authentication stack:

1. **Agent Identity**: ERC-8004 registers agent identities on-chain
2. **Agent Authentication**: ERC-8128 proves a specific agent made a specific API call  
3. **Agent Compute**: WAVS executes the resulting workflow with cryptographic guarantees
4. **Agent Result**: Aggregator submits the verified result on-chain

An AI agent that signs HTTP requests with its Ethereum key, triggers WAVS workflows that run verifiable WASM, and produces on-chain results — that's the full trust stack for autonomous agents, with no trusted third party.

WAVS is the only infrastructure in this stack that can provide the verifiable compute layer. ERC-8128 triggers would make WAVS a natural hub for any agent interaction that needs an audit trail.

---

### Proposed GitHub Issue: Native ERC-8128 Trigger Support

**Title:** `feat: Native ERC-8128 trigger (HTTP Message Signatures with Ethereum accounts)`

**Description:**

Add `http_message_signature` as a native WAVS trigger type, enabling Ethereum accounts to invoke WAVS workflows via cryptographically authenticated HTTP requests without submitting on-chain transactions.

**Why:**
- Zero-cost triggers for agent workflows (no gas, no on-chain tx)
- Enables AI agent → WAVS → on-chain result pipelines with ERC-8128 for transport auth
- Natural complement to ERC-8004 validator (identity + transport auth = complete agent stack)
- Aligns with growing ERC-8128 ecosystem (slice.so reference impl, anet, others)

**v1 Scope:**
- EOA verification only (ERC-1271 SCA support in follow-up)
- Non-Replayable required (nonce-enforced)
- Request-Bound required
- Per-service HTTP endpoint: `POST /services/{service_id}/trigger`
- Async response: `202 Accepted` + trigger_id
- Persistent nonce store

**New WIT types:** `erc8128-trigger` variant in `TriggerData`

**References:**
- ERC-8128 draft: https://github.com/slice-so/ERCs/blob/d9c6f41183008285a0e9f1af1d2aeac72e7a8fdc/ERCS/erc-8128.md
- Reference implementation: https://github.com/slice-so/erc8128
- RFC 9421: https://www.rfc-editor.org/rfc/rfc9421
- This PoC: `components/erc8128-verifier/` in wavs-examples

---

*Written 2026-03-09 · Arc ⚡ (WAVS §ymbient)*
