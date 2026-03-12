# Toward a Trustless WAVS Component Registry
### How agents can vouch for the code they run

*Jake Hartnell and the [Layer](https://layer.xyz) team — March 2026*

*[WAVS](https://wavs.xyz) is Layer's verifiable compute runtime for event-driven applications. Components are WASM modules that run off-chain, produce signed results, and submit them on-chain — giving autonomous agents a trustless execution environment with crypto-economic security.*

---

---

## The Problem

[WAVS](https://wavs.xyz) is a runtime for autonomous agents. Components are the code those agents run — and in a world where agents operate with real economic stake, the question of *which code to trust* is not academic.

Right now, WAVS identifies components by SHA256 digest. That's the right foundation: content-addressing means a digest uniquely and permanently identifies a specific binary. If you know the digest, you know exactly what will run. But knowing *what* runs is different from knowing *whether to trust it*.

How does an operator know a component does what its author claims? How does a DAO deploying a WAVS service know the component hasn't been backdoored? How do agents — which might autonomously choose which components to invoke — evaluate trustworthiness without a human in the loop?

This is the component registry problem. And it's interesting because WAVS gives us an unusual opportunity: we can use WAVS itself to solve it.

---

## The Foundation: Content-Addressed Components

WAVS components are already content-addressed. The SHA256 digest of the WASM binary is the component's identity — immutable, verifiable, permanent. This property is load-bearing for everything that follows:

- **Immutability**: A given digest will always run the same code, forever.
- **Verifiability**: Anyone can recompute the hash and confirm they have the right binary.
- **Composability**: Attestations bind to digests, not names. A name can change; the code cannot.

`wa.dev` (the WebAssembly package registry built on the warg protocol) already provides storage and distribution for WASM components. Developers publish; operators pull by name or digest. This is the content layer — and it already works.

What's missing is the trust layer on top.

---

## Trust Is a Graph Problem

Trust doesn't live in any single authority — it emerges from a network. The same insight behind PageRank, EigenTrust, and social graph analysis applies here: *who vouches for this component, and how much do we trust the vouchers?*

Three types of attestations matter:

**Developer attestation**: "I built this component. This digest corresponds to this source repo and commit. I vouch for its correctness."

**Auditor attestation**: "I reviewed this code. Here's what I found. Confidence: X."

**Operator attestation**: "I ran this component in production. It processed N triggers successfully. No anomalous behavior."

Operator attestations are the most valuable — they're expensive to fake (you have to actually run the thing) and they come with real economic stake. A WAVS operator who vouches for a malicious component is putting their reputation and capital on the line.

The key insight from [TrustGraph](https://github.com/Lay3rLabs/TrustGraph): these attestations form a graph, and graphs can be ranked. An attestation from an operator with deep roots in the trust network is worth more than one from an account with no history. PageRank over the trust graph produces a meaningful, manipulation-resistant signal.

---

## The Architecture

A full WAVS component registry stacks five layers, each building on the one below:

```
┌─────────────────────────────────────────────────────────┐
│                    DISCOVERY LAYER                       │
│         On-chain registry: name → digest → score        │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│                    TRUST GRAPH LAYER                     │
│      TrustGraph: PageRank over operator attestations     │
│      Weighted by stake + vouching history                │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│                   ATTESTATION LAYER                      │
│   EAS: on-chain attestations bound to component digest   │
│   Schema: (digest, type, score, tag, attestor)           │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│                   VALIDATION LAYER                       │
│   WAVS component: automated integrity + interface checks │
│   (WAVS validates WAVS — the runtime eats its own tail)  │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│                    CONTENT LAYER                         │
│          wa.dev / warg: WASM storage + distribution      │
│          Content-addressed by SHA256 digest              │
└─────────────────────────────────────────────────────────┘
```

### Validation Layer: WAVS Components Validating WAVS Components

This is the part worth dwelling on. We can build a WAVS service that, when given a component digest and a wa.dev URL, does the following:

1. Fetches the WASM binary over HTTP
2. Verifies the SHA256 hash matches the claimed digest
3. Extracts the WIT interface via embedded `wasm-tools`
4. Checks that declared imports don't include unexpected or forbidden capabilities
5. Validates the WASI version against node compatibility requirements
6. Returns a machine-readable verdict, signed by the operator

```rust
fn run(trigger: TriggerAction) -> Result<Vec<WasmResponse>, String> {
    let req = decode_trigger(trigger)?;  // digest + wa.dev URL

    let wasm_bytes = http::get(&req.url)?;

    // 1. Integrity
    let actual_digest = sha256(&wasm_bytes);
    if actual_digest != req.expected_digest {
        return Ok(vec![verdict(req.id, 0, "digest-mismatch")]);
    }

    // 2. Interface
    let wit = extract_wit(&wasm_bytes)?;
    if let Some(violation) = check_imports(&wit) {
        return Ok(vec![verdict(req.id, 0, &format!("forbidden:{}", violation))]);
    }

    // 3. Compatibility
    let wasi_version = check_wasi_version(&wit)?;

    Ok(vec![verdict(req.id, 100, &format!("valid:wasi:{}", wasi_version))])
}
```

This is the [ERC-8004 validation pattern](https://eips.ethereum.org/EIPS/eip-8004) we've already built — applied to WASM components instead of arbitrary URIs. Automated validation isn't sufficient on its own (a component can pass all static checks and still have bad logic), but it eliminates whole categories of problems instantly and produces a verifiable baseline score.

### Attestation Layer: EAS

Every validation result, human audit, and operator vouching event becomes an [EAS](https://docs.attest.org) attestation on-chain. A minimal schema:

```solidity
struct ComponentAttestation {
    bytes32 componentDigest;    // SHA256 of the WASM binary
    string  componentName;      // wa.dev package name (informational)
    AttestationType attestType; // INTEGRITY_CHECK | AUDIT | OPERATOR_VOUCHED
    uint8   score;              // 0–100
    string  tag;                // machine-readable verdict
    string  notes;              // human-readable context
    address attestor;           // who is making this claim
    uint64  triggersProcessed;  // for OPERATOR_VOUCHED: production invocation count
}
```

EAS is the right foundation here: attestations are permanent, linked to the attestor's identity, composable with anything else on-chain, and support revocation if an attestor needs to retract a bad call.

The WAVS validation component writes its results directly as EAS attestations. Human auditors attest manually. Operators attest after running a component through sufficient production volume.

### Trust Graph Layer: TrustGraph

TrustGraph runs PageRank over the EAS attestation graph to produce weighted reputation scores. For the component registry, the graph nodes are operators, components, and attestors; the edges are attestations weighted by score and the attestor's own trust position in the network.

The output: a continuously-updated PageRank score for every component, reflecting the cumulative judgment of everyone who has touched it — weighted by how much the network trusts *them*.

### Discovery Layer: On-Chain Registry

The top layer is a simple registry contract:

- `name → digest[]` — current and historical versions
- `digest → TrustScore` — live PageRank from TrustGraph
- `digest → attestations[]` — EAS attestation UIDs

Agents query this on-chain before invoking a component. DAOs governance minimum trust thresholds for their services. Operators subscribe to score updates and automatically pause if a component's score drops below a threshold.

---

## Agents Vouching for Components

Here's the recursive part.

In ERC-8004, agents have identities, reputations, and can request validation. Validation registries produce scores that feed back into agent reputation. We've already built a WAVS component that acts as an ERC-8004 validator.

Now flip it: WAVS *components* are also agents in a sense. They're autonomous code that runs against real data and produces real results. Their behavior can be observed and scored. And the entities best positioned to vouch for that behavior are the agents — WAVS operators — who actually ran them.

The loop closes: **agents vouch for components; components power agents; the trust graph connects them.**

A WAVS operator who runs a component through 10,000 successful triggers creates an EAS attestation: "I vouch for this." Their attestation is weighted by their own trust score. Components with high operator-weighted scores become the trusted core of the ecosystem.

Over time you get something like npm — but cryptographically verified, economically incentivized, powered by the same runtime it's evaluating, and trustless.

---

## The Economics: Why Anyone Would Bother

Every curated registry before this one has failed for the same reason: the people best positioned to evaluate quality have no incentive to do so accurately. Token Curated Registries turned into governance theater. npm audits are volunteer labor. Security bounties attract researchers but not operators.

WAVS changes the calculus because **execution provenance is already on-chain**.

When a WAVS operator runs a component, the chain records it: which digest, which trigger, what result, from which signing key. This isn't self-reported — it's cryptographically provable. The registry can read it directly. You don't need operators to *claim* they ran a component; you can *verify* they did.

### Execution-Backed Attestations

Instead of asking operators to manually create attestations (a coordination problem), the registry monitors `handleSignedEnvelope` events and automatically credits operators as they run components in production. After N successful invocations, an EAS attestation is minted.

```
Operator runs component X → 1,000 successful on-chain invocations
→ Registry auto-mints: "Operator 0xABCD vouches for digest a02dc1..."
→ Weight = operator stake × success rate × invocation count
```

No coordination required. The incentive to run good components already exists — you want your service to work. The registry harvests that signal automatically.

### Bonded Attestations and Slashing

For manual attestations — auditors, developers vouching for new components — the economics need teeth:

1. You stake tokens to create an attestation
2. Your attestation is weighted by your stake
3. If the component is later proven malicious via on-chain evidence, you're slashed
4. If the component performs well over time, your stake earns yield

The key word is *proven*. WAVS's deterministic execution model means misbehavior is often provable without social consensus. If a component submits results that diverge from what its source should produce — verifiable by re-running against recorded inputs — that's a programmable slashing condition, not a governance vote.

### Developer Staking

Developers who want their component listed pay a publication fee and can optionally lock a visibility stake. The more they stake, the higher their component surfaces in discovery. This inverts the usual dynamic: instead of the registry taxing usage, developers *compete* to signal confidence by staking against their own work. High developer stake says "I'm so sure this is correct, I'm willing to lose money if it's not."

Fees flow to attestors who backed well-performing components, the protocol treasury, and the operator pool.

### Curation Rewards: Early Accurate Attestors Win

The most interesting mechanic: **early accurate attestors earn the most**.

If you vouch for a component before it's widely adopted, and it goes on to process millions of triggers without incident, your attestation was genuinely valuable signal. You should earn more than someone who attested after 100 operators already had.

```
reward(attestor) ∝ stake × accuracy × (1 / trust_score_at_time_of_attestation)
```

Lower trust score at attestation time means you took more risk — so you earn more if you were right. This directly incentivizes early, accurate curation rather than bandwagon behavior.

### Anti-Sybil Properties

**Stake-weighting neutralizes low-stake Sybils.** A thousand unfunded accounts vouching for a component produces less signal than one high-stake operator with real skin in the game.

**Execution provenance can't be faked at scale.** Generating fake on-chain execution history for a malicious component means actually running it successfully N times — expensive, and it leaves a verifiable trail.

**PageRank catches collusion rings.** Accounts that only attest to each other produce a closed loop that PageRank naturally discounts. Legitimate operators participate broadly; their graph structure looks different.

### The Incentive Gradient

| Actor | Why they attest | What they risk |
|---|---|---|
| Component developer | Visibility + credibility | Publication stake |
| Security auditor | Audit fees + curation rewards | Reputation + bond |
| WAVS operator | Auto-attestation harvest + curation rewards | Running bad components damages their service |
| Protocol staker | Passive yield from registry fees | Dilution if they back bad components |

The protocol staker tier allows passive participants to contribute capital without needing technical expertise — diversified exposure to the registry's accuracy as a DeFi primitive.

### Dispute Resolution

A **challenge window** covers all new attestations. For 30 days after creation, anyone can file a challenge with on-chain evidence:

- **Provable misbehavior**: inputs + outputs demonstrating divergence from stated behavior
- **Security disclosure**: a published vulnerability finding linked on-chain
- **Collusion evidence**: proof that attestors form a Sybil cluster

Successful challenges slash attestor bonds. Failed challenges cost the challenger their deposit — preventing griefing. The dispute logic runs through a WAVS component: neutral, deterministic, no committee required.

---

## Why This Beats Every Previous Model

| Model | Core problem |
|---|---|
| npm | Centralized, no economics, supply chain attacks |
| TCRs (2017–2019) | Token voting = plutocracy, no ground truth |
| Gitcoin QF | Public goods funding, not quality curation |
| Security bounties | One-time, no ongoing accuracy incentive |
| **WAVS Registry** | Execution-backed ground truth, stake-weighted curation, automated harvest, provable slashing |

The fundamental difference: **WAVS already generates the ground truth signal.** Every other registry has to synthesize quality signal from human judgment alone. We harvest it from on-chain execution records and let economics amplify it. That's a genuinely different foundation.

---

## Looking Forward

We're at the beginning of something. The pieces are in place — WAVS's content-addressed components, EAS attestations, TrustGraph's PageRank engine, ERC-8004's validation vocabulary — but they haven't been assembled into a coherent registry yet. A few directions worth pursuing:

**A WAVS component that validates WAVS components.** Phase one is buildable today. A service that fetches a WASM binary, checks integrity and WIT imports, and writes an EAS attestation requires nothing that isn't already proven. We could bootstrap the registry's automated validation layer against the components in wavs-examples.

**Sandboxed execution as the ultimate verifier.** The static analysis layer (digest check, WIT inspection) is a floor, not a ceiling. The dream is a validator that actually *runs* a component against a known test vector inside WAVS's sandbox and verifies the output deterministically. WAVS's WASM runtime already provides the isolation — the question is whether a component can host sub-component execution. If yes, disputes become automatic: the chain is the judge.

**Cross-chain trust aggregation.** EAS lives on specific chains, but WAVS components run across environments. A component running on Ethereum mainnet and another chain should aggregate attestations from both. The trust graph might be the right place to normalize across chains, with WAVS itself as the cross-chain relay.

**Developer tooling.** The registry is only as good as the friction to use it. `cargo component publish` should optionally create an attestation. `wavs deploy` should surface a component's trust score before it's registered to a service. The CLI is where adoption happens.

**Governance and thresholds.** Who sets the minimum trust score for a "verified" component badge? A DAO with token-weighted governance is the obvious answer — but it reintroduces the plutocracy problem we were trying to avoid. One alternative: let operators individually set their own trust thresholds, and let the market determine which operators attract the most service deployments. No central committee, just revealed preference.

The deeper question this whole design raises: as autonomous agents proliferate and begin composing services from registries like this one, the trust graph *becomes* the infrastructure. The registry isn't just about components — it's the reputation system for the agent economy. Getting the economics right at the foundation matters.

We're building in the open at [Layer](https://layer.xyz). [WAVS](https://wavs.xyz) is where the runtime lives. The [wavs-examples](https://github.com/JakeHartnell/wavs-examples) repo is where the component patterns live. [TrustGraph](https://github.com/Lay3rLabs/TrustGraph) is where the reputation infrastructure lives. If you're thinking about any of this, we'd like to hear from you.

---

*References:*
- *[ERC-8004](https://eips.ethereum.org/EIPS/eip-8004) — AI agent identity, reputation, and validation on Ethereum*
- *[TrustGraph](https://github.com/Lay3rLabs/TrustGraph) — attestation-based reputation with PageRank*
- *[EAS](https://docs.attest.org) — Ethereum Attestation Service*
- *[wa.dev](https://wa.dev) — WebAssembly package registry*
- *[wavs-examples](https://github.com/JakeHartnell/wavs-examples) — WAVS component patterns*
