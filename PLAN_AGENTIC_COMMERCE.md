# Execution Plan: Agentic Commerce Example

**Goal:** Build `examples/agents/01-agentic-commerce/` — a WAVS-powered agent job market using ERC-8183 (Agentic Commerce) with ERC-8004 reputation attestation.

**Theme:** "An agent economy where WAVS is the trusted evaluator."

---

## What Makes This Different

Previous examples use the `NewTrigger(uint64 triggerId, bytes data)` wrapper pattern. This example listens directly to a real semantic contract event:

```
JobSubmitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable)
```

No `TriggerId`, no `NewTrigger` wrapper. WAVS subscribes to a domain-specific event from a real standards-track contract.

---

## Demo Narrative

> An on-chain job market where clients pay agents to fetch URLs and certify their content. The WAVS aggregator is the evaluator — it independently fetches the same URL, computes the hash, and either releases payment or rejects the claim. All cryptographically attested.

Flow:
1. Client deploys a job: "Fetch `https://httpbin.org/json` and certify its hash. Budget: 100 TEST."
2. Client funds escrow (tokens locked in AgenticCommerce contract)
3. Provider agent fetches the URL, computes `keccak256(content)`, calls `submit(jobId, deliverableHash)`
4. `JobSubmitted` event fires → **WAVS wakes up**
5. WAVS component: fetches same URL, computes hash, compares to deliverable
   - Match → calls `complete(jobId, attestationHash)` → provider paid ✅
   - Mismatch → calls `reject(jobId, reason)` → client refunded ✅
6. ReputationHook: on completion, writes feedback to ERC-8004 ReputationRegistry

---

## Contracts to Build

### 1. `AgenticCommerce.sol` (ERC-8183 implementation)

Minimal, clean implementation. No extras.

```solidity
// Events WAVS listens to:
event JobSubmitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable);
event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 reason);
event JobRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason);

// State machine:
// Open → Funded → Submitted → {Completed, Rejected, Expired}

struct Job {
    address client;
    address provider;
    address evaluator;    // WAVS aggregator address
    address hook;         // optional: ReputationHook
    string  description;  // job brief (we encode URI here for the demo)
    uint256 budget;
    uint64  expiredAt;
    JobStatus status;
}

function createJob(address provider, address evaluator, uint64 expiredAt, string calldata description, address hook) external returns (uint256 jobId);
function setBudget(uint256 jobId, uint256 amount) external;
function fund(uint256 jobId, uint256 expectedBudget) external;
function submit(uint256 jobId, bytes32 deliverable) external;
function complete(uint256 jobId, bytes32 reason) external;  // evaluator only
function reject(uint256 jobId, bytes32 reason) external;    // evaluator (or client if Open)
function claimRefund(uint256 jobId) external;               // anyone, after expiry
```

Payment token: simple ERC-20 (deploy `MockERC20` for the demo on Anvil).

**Key design:** WAVS aggregator address = `evaluator`. When WAVS calls `complete()`, it's the only entity that can do so after submission. This is trust enforced by the contract.

### 2. `ReputationHook.sol` (ERC-8183 hook → ERC-8004 writer)

Implements `IACPHook`. Calls ERC-8004 ReputationRegistry on job completion.

```solidity
interface IACPHook {
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
}

// afterAction for COMPLETE_SELECTOR:
//   → reputationRegistry.addFeedback(agentId, clientAddress, value, valueDecimals, tag1, tag2, feedbackURI, feedbackHash)
//   For demo: agentId = provider's registered agentId (stored in hook config)
//             value = 100 (full score), tag1 = "acp:complete"
```

For the Anvil demo, we deploy a minimal ReputationRegistry (no IdentityRegistry requirement — just `addFeedback`). For testnet, we can point at the live contracts.

### 3. `MockERC20.sol`

Simple ERC-20 with public `mint()`. Already exists in most foundry templates.

### 4. `IAgenticCommerce.sol`

Shared interface + events for the component's `sol!()` macro.

### 5. Deploy Script: `script/DeployAgenticCommerce.s.sol`

```
1. Deploy MockERC20 (or reuse existing)
2. Deploy ReputationRegistry (minimal, no IdentityRegistry dep)
3. Deploy AgenticCommerce
4. Deploy ReputationHook(reputationRegistry, agenticCommerce)
```

---

## WAVS Component: `agentic-commerce-evaluator`

### Trigger Configuration

```json
{
  "trigger": {
    "evm_contract_event": {
      "address": "<AgenticCommerce address>",
      "chain": "eip155:31337",
      "event_hash": "0x<keccak256('JobSubmitted(uint256,address,bytes32)')>"
    }
  }
}
```

**event_hash** = `keccak256("JobSubmitted(uint256,address,bytes32)")` = `0x...` (compute with cast)

### Component Logic (`src/lib.rs`)

```
1. Receive TriggerData::EvmContractEvent
2. Decode JobSubmitted log:
   - topic[1] = jobId (bytes32 → u256)
   - topic[2] = provider address
   - data = deliverable (bytes32)
3. Call back into AgenticCommerce via view call (or read job from emit data):
   - getJob(jobId) → description contains the URL to verify
4. HTTP GET the URL
5. Compute keccak256(response_body)
6. Compare computed_hash vs deliverable
7. Encode output:
   - if match:   abi.encode(complete(jobId, computed_hash))
   - if no match: abi.encode(reject(jobId, computed_hash))  // reason = what we got
```

### Output Encoding

The WasmResponse payload encodes a contract call. The aggregator broadcasts it.

```rust
pub struct EvaluationOutput {
    pub job_id: u256,
    pub verdict: Verdict,
    pub attestation_hash: FixedBytes<32>,
}

// payload = abi.encode(JobVerdict { jobId, isComplete, attestationHash })
// Submit contract calls agenticCommerce.complete() or .reject() based on isComplete
```

Wait — WAVS needs a **submit contract** that receives the payload and routes to the right call. Options:

**Option A: Evaluator Submit Contract**
```solidity
contract EvaluatorSubmit is WavsServiceHandler {
    AgenticCommerce public acp;

    function handleSignedData(bytes calldata data, ...) external {
        (uint256 jobId, bool isComplete, bytes32 attestation) = abi.decode(data, (uint256, bool, bytes32));
        if (isComplete) {
            acp.complete(jobId, attestation);
        } else {
            acp.reject(jobId, attestation);
        }
    }
}
```

**Option B: Make AgenticCommerce itself the submit contract**
Implement `handleSignedData` directly on AgenticCommerce. Decodes the payload and calls internal `_complete` / `_reject` with the aggregator's verified authority.

Option B is cleaner — one contract, no proxy needed. The evaluator address = WAVS aggregator = `_msgSender()` on the WAVS-verified call.

Actually, looking at how our existing submit contracts work — WAVS submits to a contract via the aggregator's signed transaction. The aggregator IS `msg.sender`. So `AgenticCommerce` just needs `evaluator` == aggregator address, and the aggregator calls `complete()` / `reject()` directly. No submit contract needed.

### No Submit Contract Needed!

Because `evaluator` = WAVS aggregator address, and WAVS signs transactions, the aggregator can call `complete()` / `reject()` directly as `msg.sender`. The existing authorization check (`require(msg.sender == job.evaluator)`) handles it.

The WasmResponse encodes the calldata that the aggregator will broadcast:
```rust
WasmResponse {
    payload: complete_call.abi_encode(),  // or reject_call.abi_encode()
    ..
}
```

We still need a WAVS submit handler that the aggregator calls — but it's just a thin wrapper:

```solidity
contract AgenticCommerceEvaluator {
    IAgenticCommerce public acp;

    // Called by WAVS aggregator with the encoded verdict
    function handleEvaluation(bytes calldata payload) external {
        (uint256 jobId, bool isComplete, bytes32 attestation) =
            abi.decode(payload, (uint256, bool, bytes32));
        if (isComplete) {
            acp.complete(jobId, attestation);
        } else {
            acp.reject(jobId, attestation);
        }
    }
}
```

`evaluator` in each job = this contract's address. The WAVS aggregator calls `handleEvaluation()`. `msg.sender` = aggregator = the service manager. `handleEvaluation` calls `acp.complete()` as the evaluator contract.

---

## Directory Layout

```
examples/agents/01-agentic-commerce/
├── README.md              # Example docs
├── contracts/
│   ├── AgenticCommerce.sol
│   ├── AgenticCommerceEvaluator.sol   # thin WAVS submit handler
│   ├── ReputationHook.sol             # ERC-8183 hook → ERC-8004
│   ├── MockERC20.sol
│   └── interfaces/
│       ├── IAgenticCommerce.sol
│       └── IERC8004.sol               # ReputationRegistry interface
├── component/
│   └── agentic-commerce-evaluator/
│       ├── Cargo.toml
│       ├── wit/                       # WIT bindings (per-component, as always)
│       └── src/
│           ├── lib.rs
│           └── trigger.rs
├── script/
│   └── Deploy.s.sol
└── scripts/
    └── demo.sh
```

Or integrate into existing structure:
- Contracts → `src/contracts/AgenticCommerce*.sol`
- Component → `components/agentic-commerce-evaluator/`
- Script → `script/DeployAgenticCommerce.s.sol`
- Shell → `scripts/demo-agentic-commerce.sh`

---

## ERC-8004 Integration Details

### What We Deploy vs. What We Reuse

| Contract | Source | Anvil | Sepolia |
|----------|--------|-------|---------|
| IdentityRegistry | erc-8004/erc-8004-contracts | Deploy | `0x8004A818BFB912233c491871b3d84c89A494BD9e` |
| ReputationRegistry | erc-8004/erc-8004-contracts | Deploy | `0x8004B663056A597Dffe9eCcC1965A193B7388713` |
| ValidationRegistry | erc-8004/erc-8004-contracts | Deploy | Not deployed (we deploy our own) |
| AgenticCommerce | ours (ERC-8183) | Deploy | Deploy |
| ReputationHook | ours | Deploy | Deploy |

For the Anvil demo: deploy everything locally, no external dependencies.
For testnet demo: use official IdentityRegistry + ReputationRegistry on Sepolia; deploy AgenticCommerce + hook.

### Reputation Write (after complete)

```solidity
// In ReputationHook.afterAction (COMPLETE_SELECTOR):
reputationRegistry.addFeedback(
    agentId,           // provider's ERC-8004 agentId (looked up from provider address)
    msg.sender,        // clientAddress = evaluator (WAVS contract)
    100,               // value (full score)
    0,                 // valueDecimals
    "acp:complete",    // tag1
    "",                // tag2
    "",                // feedbackURI
    bytes32(0)         // feedbackHash
);
```

For demo simplicity: the hook stores a mapping `provider_address → agentId`. The deploy script registers providers and stores their agentIds.

---

## Event Hash Computation

```bash
cast keccak "JobSubmitted(uint256,address,bytes32)"
# → 0x<event_hash for service.json>
```

This is the `event_hash` field in the WAVS service JSON. This is cleaner than looking for a NewTrigger wrapper — it's the actual semantic event.

---

## What "Realistic" Means Here

| Old pattern (our examples) | New pattern (this example) |
|---------------------------|---------------------------|
| `NewTrigger(uint64 triggerId, bytes data)` | `JobSubmitted(uint256 jobId, address provider, bytes32 deliverable)` |
| Generic envelope | Semantic domain event |
| Decode `TriggerInfo` struct | Decode real event topics directly |
| Submit to `WavsSubmit` handler | Submit to `AgenticCommerceEvaluator` |
| Trigger is a WAVS artifact | Trigger is a real ERC-8183 event |

The component code changes slightly:
- Topics[1] = jobId (indexed uint256)
- Topics[2] = provider (indexed address)
- Data = deliverable (bytes32, non-indexed)

---

## Build Order

### Phase 1: Contracts
1. `AgenticCommerce.sol` — full ERC-8183 state machine
2. `IAgenticCommerce.sol` — events + structs
3. `AgenticCommerceEvaluator.sol` — WAVS submit handler
4. `MockERC20.sol` — payment token (reuse if exists)
5. `script/DeployAgenticCommerce.s.sol` — deploy all, output addresses

### Phase 2: Component
6. `components/agentic-commerce-evaluator/` — scaffold (copy from erc8004-validator)
7. `trigger.rs` — decode `JobSubmitted` event from log topics
8. `lib.rs` — HTTP fetch URL from job description, hash, compare, encode verdict
9. Build + upload to WAVS node

### Phase 3: Integration
10. `scripts/demo-agentic-commerce.sh` — end-to-end demo script:
    - Deploy contracts
    - Upload component + register service (trigger = JobSubmitted event)
    - Mint TEST tokens, approve AgenticCommerce
    - Create job (description = target URL)
    - Set budget, fund
    - Provider submits deliverable (correct hash)
    - Wait for WAVS to evaluate → complete
    - Verify job.status == Completed, check payment received

### Phase 4: ERC-8004 Layer (can be deferred)
11. Port/deploy `ReputationRegistry.sol` from erc-8004/erc-8004-contracts
12. `ReputationHook.sol` — afterAction hook → addFeedback
13. Wire hook into deploy script
14. Add reputation check to demo script

---

## Open Questions

1. **Job description encoding**: Simple approach — job.description is the URL string. Provider knows the URL (from description), fetches it, computes hash. WAVS reads description from event log or via contract view call. Which is better?
   - **Via view call** (`getJob(jobId)`) requires WAVS to make an RPC call back to the chain. This is possible but adds complexity.
   - **Via additional event data** — emit description in JobCreated, not indexed. WAVS would need to correlate.
   - **Simplest**: Encode URL in deliverable topic differently — but deliverable is bytes32, not string.
   - **Best**: WAVS reads job description from `AgenticCommerce.getJob(jobId).description` via eth_call. We've done RPC reads before in components.

2. **WAVS submit handler architecture**: Does WAVS aggregator call `complete()/reject()` directly, or via `AgenticCommerceEvaluator`? Direct is simpler. Via evaluator contract is more explicit. Going with evaluator contract — it's the cleaner separation and matches how service managers work.

3. **ERC-8004 for Phase 1**: Skip ReputationHook for Phase 1, add in Phase 2. Keep the contract hook-aware (`hook` field can be `address(0)`) so adding later is clean.

4. **Token**: Deploy a `MockERC20` with `mint()` for the demo. Don't complicate with real USDC.

---

## References

- ERC-8183 spec: https://eips.ethereum.org/EIPS/eip-8183
- ERC-8004 spec: https://eips.ethereum.org/EIPS/eip-8004
- erc-8004-contracts: https://github.com/erc-8004/erc-8004-contracts
- ERC-8004 Sepolia: IdentityRegistry `0x8004A818BFB912233c491871b3d84c89A494BD9e`, ReputationRegistry `0x8004B663056A597Dffe9eCcC1965A193B7388713`
- Our ERC-8128 research: `ERC8128_RESEARCH.md`

---

*Written 2026-03-10 · Arc ⚡*
