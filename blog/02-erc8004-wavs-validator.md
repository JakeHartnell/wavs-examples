# WAVS as a Trustless ERC-8004 Validator

*Verifiable compute meets the open agent economy*

---

## The Problem with Agent Trust

AI agents are becoming economic actors. They book flights, manage portfolios, coordinate workflows. But there's a fundamental problem: **how do you trust an agent you've never worked with before?**

Today you can't. Every interaction with an unknown agent is a leap of faith. There's no shared identity layer. No verifiable track record. No way to check whether an agent's claimed outputs were actually produced correctly.

[ERC-8004](https://eips.ethereum.org/EIPS/eip-8004) is a draft Ethereum standard trying to fix this. It proposes three on-chain registries that give agents what they currently lack:

- **Identity** — portable, NFT-based registration agents can take across platforms
- **Reputation** — on-chain feedback from real clients, publicly queryable
- **Validation** — cryptographic proofs that an agent's work was actually correct

The third one is where WAVS comes in.

---

## What the Validation Registry Does

ERC-8004's Validation Registry lets agents request independent verification of their work. An agent publishes its output, commits a keccak256 hash of the data, and requests that a validator check it.

The registry doesn't care *how* validation works — it just records the request and the response:

```solidity
function validationRequest(
    address validatorAddress,
    uint256 agentId,
    string calldata requestURI,
    bytes32 requestHash
) external;

function validationResponse(
    bytes32 requestHash,
    uint8 response,    // 0 = fail, 100 = pass
    string calldata responseURI,
    bytes32 responseHash,
    string calldata tag
) external;
```

The spec explicitly lists the validation methods it's designed for:
- **Crypto-economic security** — stakers re-execute the work and vote
- **zkML proofs** — zero-knowledge proofs of model execution
- **TEE attestations** — trusted execution environment oracles

WAVS implements all three paths. But let's start with the most immediately useful one.

---

## WAVS as a Hash Integrity Validator

The simplest thing a WAVS component can verify is content integrity. An agent commits to a URI + hash, and the WAVS validator:

1. Fetches the content at the URI
2. Computes keccak256 of the response
3. Compares to the committed hash
4. Returns 100 (pass) or 0 (fail) — signed by the operator, submitted on-chain

This is useful because it's **trustless**. The validator doesn't require you to trust the agent, the validator, or even the WAVS operator individually. The signed result is on-chain. Anyone can verify it. The WAVS operator's key is registered with a stake — if they lie, they can be slashed.

Here's the entire component logic:

```rust
impl Guest for Component {
    fn run(action: TriggerAction) -> Result<Vec<WasmResponse>, String> {
        let trigger = decode_trigger_event(action.data)?;

        // Fetch content at the URI
        let content = http::get(&trigger.request_uri)?;

        // Compute keccak256
        let computed_hash = keccak256(&content);

        // Return the hash — submit contract does the on-chain comparison
        Ok(vec![encode_validation_output(trigger.trigger_id, computed_hash.into())])
    }
}
```

That's it. The component is deterministic, auditable, and WASM-sandboxed. The result is signed by a registered operator key and submitted to the ValidationSubmit contract, which does the pass/fail comparison on-chain:

```solidity
bytes32 computedHash = abi.decode(dataWithId.data, (bytes32));
ValidationRequest memory req = _trigger.getRequest(dataWithId.triggerId);
uint8 response = (computedHash == req.requestHash) ? 100 : 0;
```

---

## The Architecture

```
User/Agent
    │
    ▼
ValidationTrigger.requestValidation(uri, hash)
    │
    │ emits NewTrigger(TriggerInfo{...})
    ▼
WAVS Node (event subscription)
    │
    ▼
erc8004-validator component (WASM)
    │  • HTTP GET uri
    │  • keccak256(content)
    │  • return computed_hash
    ▼
Aggregator (signing)
    │
    ▼
ValidationSubmit.handleSignedEnvelope(...)
    │  • verify operator signature
    │  • compare computed_hash vs stored requestHash
    │  • store ValidationResult on-chain
    ▼
On-chain result queryable by anyone
```

One trigger, one WASM execution, one signed on-chain result. The whole pipeline runs in seconds.

---

## Why This Matters for the Agent Economy

ERC-8004 is about creating a **permissionless trust layer** for agents. The draft was put together by AI leads at MetaMask and the Ethereum Foundation, with contributions from 50+ organizations. It's already live on Ethereum mainnet.

The three-registry design is smart because it separates concerns:
- Identity (who is this agent?) from
- Reputation (what do clients say?) from
- Validation (did the agent do what it claimed?)

WAVS is a natural fit for the third layer. WAVS was built precisely for the use case of "run some computation off-chain, prove it on-chain, do it trustlessly." That's the validation registry's whole job.

The validator we built today is intentionally simple — hash integrity. But the same architecture works for:

- **Re-execution validators**: WAVS component re-runs the agent's model and checks the output matches
- **API validators**: Verify the agent fetched real external data (price feeds, weather, etc.)
- **Format validators**: Check that output conforms to a schema before payment releases
- **Composite validators**: Chain multiple checks, each WAVS-attested separately

---

## The Bigger Picture

There's something philosophically interesting happening here. ERC-8004 is infrastructure for agent trust in a world where trust between autonomous systems is hard. WAVS is infrastructure for trustless computation. They're solving complementary problems.

ERC-8004 asks: "Which agents should I trust?"
WAVS answers: "Here's cryptographic proof of what they actually did."

Together they sketch an architecture for an agent economy that doesn't require trusting any single party. Agents register on-chain. Clients leave verifiable feedback. Validators (like WAVS) cryptographically attest to correctness. The whole thing is composable, permissionless, and auditable.

This isn't science fiction. We built it in a few hours. The component runs, the signature is valid, the hash is on-chain.

---

## What's Next

The hash integrity validator is a starting point. The more interesting path is:

1. **ERC-8004 Identity integration** — register WAVS services as ERC-8004 agents on mainnet
2. **Reputation feedback** — have clients post on-chain feedback after validator confirmations
3. **Re-execution validators** — WAVS component that re-runs an AI inference and checks determinism
4. **Composite validation** — chain multiple WAVS validators for multi-factor trust

The open agent economy needs validators it can actually trust. WAVS is how you build them.

---

*Built with WAVS on 2026-03-07.*
*Component: `erc8004-validator` — github.com/JakeHartnell/wavs-examples*
