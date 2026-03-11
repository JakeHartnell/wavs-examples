# The Agent Economy Needs a Trust Layer — WAVS + ERC-8183 Is It

*March 2026*

---

We're at a weird moment in the AI agent space. Agents can negotiate, transact, and do real economic work — but the infrastructure for *trusting* them barely exists. How does a smart contract know an agent actually did what it claimed? How does one agent verify another's output before releasing payment?

We built a demo last week that answers those questions in a way that feels like it could actually matter. Here's what it does, why it's interesting, and why the stack of ERC standards underneath it is worth paying attention to.

---

## The Problem: Agents Can Lie

Imagine an on-chain job market. A client posts a bounty: "Fetch this URL, hash the content, prove you did it." A provider agent claims the job, does the work, submits a hash. Client pays.

Except: nothing stops the provider from submitting a *wrong* hash. Maybe they cached a stale response. Maybe they fabricated it entirely. The client has no way to know without checking themselves — which defeats the whole point of hiring an agent.

You could add dispute resolution, but that means a human in the loop. Or you could require the client to double-check everything, but now you've just outsourced the verification problem without solving it.

What you actually need is a trusted third party — one that's *not* a human, *not* corruptible, and whose decision is cryptographically auditable on-chain.

That's exactly the role WAVS is built for.

---

## What We Built

We implemented [ERC-8183 (Agentic Commerce Protocol)](https://eips.ethereum.org/EIPS/eip-8183) — a draft standard for on-chain job escrow between agents — and wired WAVS in as the evaluator.

The flow looks like this:

```
Client creates job → funds escrow → Provider submits deliverable
         ↓
   JobSubmitted event fires
         ↓
   WAVS wakes up, independently verifies the work
         ↓
   WAVS attests: complete() → provider paid ✅
              or reject()   → client refunded ✅
```

Every step is on-chain. The evaluation is signed by the WAVS aggregator, verifiable by anyone. No human arbitration. No trust in the provider's word. The contract enforces the verdict.

On top of that, we hooked in [ERC-8004 (Trustless Agents)](https://eips.ethereum.org/EIPS/eip-8004) — so every completed or rejected job writes a reputation signal to an on-chain registry. Agents build (or burn) their reputations automatically, with every evaluation.

---

## Why WAVS Is the Right Evaluator

ERC-8183 has a clean abstraction: the **evaluator** is just an address. It could be the client themselves. It could be a multisig. It could be a smart contract that verifies ZK proofs.

Or it could be a WAVS service.

WAVS operators run WASM components in a deterministic, sandboxed environment. The output — whatever computation the component performs — is signed by a quorum of operators. That signature is verifiable on-chain. It's not "we promise we ran this code." It's cryptographic proof that an operator cohort processed the input and produced this output.

For an evaluator role, that's exactly the guarantee you want:
- **Deterministic**: given the same input, the same computation runs
- **Independent**: WAVS fetches and evaluates the deliverable itself — it doesn't trust the provider's claim
- **Attested**: the result is signed and posted on-chain with a hash of the evaluation
- **Automatic**: no human needed to trigger or approve

The WAVS component we built watches for `JobSubmitted` events, independently fetches the URL in the job description, computes `keccak256` of the response, and compares it against the provider's deliverable. Match → `complete()`. Mismatch → `reject()`. The provider can't game it because WAVS doesn't ask the provider for the answer.

---

## The Standards Stack

Three ERC standards are doing real work here, and they compose cleanly:

### ERC-8183: Agentic Commerce Protocol

The escrow layer. Six states, three roles (client, provider, evaluator), and a hook system for composability. The key insight is that the **evaluator is the only entity that can settle a submitted job** — neither the client nor the provider can unilaterally decide. This is what gives the protocol its trust properties.

For the demo, `evaluator` = our `AgenticCommerceEvaluator` contract, which accepts WAVS-signed payloads and calls `complete()` or `reject()` on the `AgenticCommerce` contract. WAVS signs the verdict; the contract enforces it.

### ERC-8004: Trustless Agents

The reputation layer. Agents register on-chain identities and accumulate structured feedback. In our demo, a `ReputationHook` listens to job settlements and writes feedback to the `ReputationRegistry` automatically. Every completed job is a positive signal; rejected jobs aren't. Over time, an agent's on-chain reputation becomes a verifiable track record.

This is crucial for the agent economy to function at scale. Right now, "is this agent trustworthy?" is basically vibes. With ERC-8004, it's on-chain history.

### ERC-8128: HTTP Message Signatures

We built a separate PoC for this one — it's how you verify that an HTTP request was signed by a specific key. In an agentic commerce context, this is what lets a provider prove they made a specific API call, or lets a client verify that a response came from a specific endpoint. It's the cryptographic glue between the off-chain web and on-chain verification.

These three standards are complementary by design. ERC-8128 tells you *how* the work was done. ERC-8183 provides the escrow and settlement framework. ERC-8004 tracks *who* did it and how well.

---

## What the Demo Actually Does

The full end-to-end demo:

1. Deploys all contracts to a local Anvil chain
2. Registers the provider as an ERC-8004 agent (gets an on-chain identity)
3. Builds and uploads the WAVS WASM component
4. Registers the WAVS service, pointing at the `JobSubmitted` event as its trigger
5. Client creates a job: "Fetch `https://httpbin.org/json` and verify the hash"
6. Client funds escrow: 100 tUSDC locked in the contract
7. Provider fetches the URL, computes `keccak256`, calls `submit(jobId, hash)`
8. `JobSubmitted` event fires → WAVS wakes up
9. WAVS independently fetches the same URL, computes the hash, compares
10. WAVS calls `complete(jobId, attestationHash)` through the evaluator contract
11. 100 tUSDC releases to the provider
12. `ReputationHook` fires → positive feedback written to ERC-8004 registry

The entire evaluation is automated. The provider never talks to WAVS directly. WAVS never talks to the provider. The contract is the only arbiter.

---

## Why This Is a Foundation, Not a Demo

The pattern we've built here is general. WAVS as evaluator works for any job where "correct output" is computationally verifiable:

- **Data verification**: Did the agent fetch fresh data? Did it match an expected schema?
- **AI task completion**: Did the agent's LLM call produce output that meets the criteria? (This is where WAVS + an LLM oracle becomes interesting)
- **Cross-chain state verification**: Did an agent correctly relay state from another chain?
- **HTTP request proof**: Did the agent actually call the API they claimed to call? (ERC-8128)
- **ZK proof verification**: Did the agent produce a valid proof?

In every case, the evaluator is a WAVS component that independently verifies the claim. The escrow contract enforces the verdict. The reputation registry tracks the history.

An agent that consistently delivers correct work builds an on-chain reputation. That reputation becomes collateral — clients can require a minimum reputation score before funding jobs. High-reputation agents can command higher budgets. The market self-organizes around verifiable track records.

---

## The Bigger Picture

We're building infrastructure for an economy that doesn't have human intermediaries at settlement time. Agents hire agents, verify each other's work, and pay each other — all mediated by contracts and cryptographic proofs.

WAVS makes that possible because it's a runtime where computation is verifiable. Not "we ran this code and trust us." Actually verifiable — signed by multiple independent operators, auditable on-chain, deterministic by construction.

ERC-8183 gives that verifiable compute a home in a real economic protocol. ERC-8004 makes the history permanent and queryable.

We think this is what the agent economy actually needs. Not more LLM APIs. Not more wallets. A trust layer that runs at machine speed, without humans in the critical path.

---

**The code is in [wavs-examples](https://github.com/JakeHartnell/wavs-examples) on the `examples` branch. The demo script is `scripts/demo-agentic-commerce.sh`.**

*Built on [WAVS](https://lay3rlabs.io) · Standards: [ERC-8183](https://eips.ethereum.org/EIPS/eip-8183) · [ERC-8004](https://eips.ethereum.org/EIPS/eip-8004) · [ERC-8128](https://eips.ethereum.org/EIPS/eip-8128)*
