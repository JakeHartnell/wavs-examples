# Standalone Repo Plan: WAVS Agentic Commerce

**Goal:** Extract the ERC-8183 demo from `wavs-examples` into its own repo — something polished enough to be a reference implementation, a developer starting point, and a demo that can run at conferences.

**Proposed repo name:** `wavs-agentic-commerce` (under `Lay3rLabs`)

---

## Why a Standalone Repo

The current implementation lives in `wavs-examples` alongside weather oracles, ERC-8004 validators, and other demos. That's fine for learning but wrong for:

- **Reference implementation**: ERC-8183 authors and adopters need a canonical WAVS evaluator example
- **Community adoption**: Developers want a repo they can `git clone` and have running in one command
- **Showcasing**: Conference demos need a clean story, not a monorepo with 10 examples
- **Iteration**: Contracts and UI will evolve separately from the foundry-template-based examples

---

## Target Repo Structure

```
wavs-agentic-commerce/
├── README.md                     # Primary entrypoint — demo first, architecture second
├── ARCHITECTURE.md               # Deep dive on the trust model
├── Taskfile.yml                  # Single entrypoint: task demo
│
├── contracts/                    # Foundry project
│   ├── foundry.toml
│   ├── src/
│   │   ├── AgenticCommerce.sol           # ERC-8183 core
│   │   ├── AgenticCommerceEvaluator.sol  # WAVS submit handler / evaluator
│   │   ├── ReputationHook.sol            # ERC-8183 hook → ERC-8004
│   │   ├── MockERC20.sol                 # tUSDC for local dev
│   │   └── interfaces/
│   │       ├── IAgenticCommerce.sol
│   │       └── IACPHook.sol
│   ├── script/
│   │   ├── Deploy.s.sol                  # Full deploy (contracts + hook wiring)
│   │   └── Trigger.s.sol                 # Manual job trigger for testing
│   └── test/
│       ├── AgenticCommerce.t.sol
│       └── AgenticCommerceEvaluator.t.sol
│
├── component/                    # WAVS WASM component (Rust)
│   ├── Cargo.toml
│   ├── wit/                      # WIT bindings (per-component pattern)
│   └── src/
│       ├── lib.rs                # Component entrypoint
│       ├── trigger.rs            # JobSubmitted event decoder
│       └── evaluator.rs          # Fetch URL, compute hash, produce verdict
│
├── aggregator/                   # Aggregator component (from wavs-foundry-template)
│   ├── Cargo.toml
│   └── src/lib.rs
│
├── ui/                           # Frontend (see UI requirements below)
│   ├── package.json
│   └── src/
│
├── scripts/
│   ├── demo.sh                   # End-to-end demo (refactored from demo-agentic-commerce.sh)
│   └── setup.sh                  # One-time environment setup
│
└── docs/
    ├── erc-8183.md               # Why this standard matters
    ├── wavs-evaluator-pattern.md  # How WAVS fits the evaluator role
    └── ui-architecture.md        # Frontend design doc
```

---

## Contract Improvements

### `AgenticCommerce.sol`

The current implementation is solid. Improvements for the standalone:

1. **`getJobDescription()` workaround → fix properly**
   - Currently we have a `getJobDescription()` view function separate from `getJob()` to work around the alloy WASM ABI decode bug with mixed static/dynamic tuples
   - Once the alloy bug is fixed upstream, remove this workaround and decode `getJob()` directly in the component
   - Track: https://github.com/alloy-rs/alloy — file an issue if one doesn't exist

2. **Events: add `deliverable` to `JobCompleted` / `JobRejected`**
   - Currently these events include `reason` (bytes32) but not the original `deliverable`
   - Makes it harder to correlate what was submitted vs. what was attested on-chain
   - Add: `event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 deliverable, bytes32 attestation)`

3. **Multi-token support (v2 scope)**
   - Current: single ERC-20 token set at deploy time
   - Better: per-job token (set at `createJob` time)
   - Enables an actual marketplace with multiple currencies

4. **Platform fee (v2 scope)**
   - ERC-8183 spec mentions optional platform fee in `complete()`
   - Wire it: `complete()` splits budget between provider and a `feeRecipient`
   - Needed before mainnet deployment

5. **Dispute window (v2 scope)**
   - Currently: submit → evaluate is instant (WAVS responds in seconds)
   - For adversarial environments: add a challenge window before `complete()` is final
   - Probably overkill for v1 but worth documenting as a known gap

6. **Gas: packing `Job` struct**
   - Current `Job` struct has `string description` which forces dynamic layout
   - Consider: emit full description in `JobCreated`, store only `bytes32 descriptionHash` on-chain
   - Description fetched from event logs by WAVS, not from state
   - Saves significant gas on `createJob()` for long descriptions

### `AgenticCommerceEvaluator.sol`

1. **Better error surfacing**
   - Currently `InvalidPayload()` / `InvalidJob()` — could include the job state
   - Add: `EvaluationAlreadyProcessed(uint256 jobId)` to prevent replays if WAVS fires twice

2. **Nonce/replay protection**
   - WAVS components are deterministic but theoretically an operator could re-submit a signed envelope
   - Track processed `triggerIds` (if using triggerID-based triggering) or `(jobId, blockHash)` tuples

3. **Emergency pause**
   - `Ownable` + `pause()` for the evaluator contract specifically
   - If a WAVS component has a bug and is completing jobs incorrectly, owner can pause the evaluator without touching the `AgenticCommerce` contract

### `ReputationHook.sol`

1. **Auto-lookup agentId from address**
   - Currently requires manual `registerAgent(address, agentId)` pre-registration
   - Better: call `IdentityRegistry.getAgentId(address)` at hook time (if ERC-8004 registry supports it)
   - Eliminates setup step from demo flow

2. **Negative feedback on reject**
   - Currently only writes positive feedback on complete
   - `reject()` should write a negative signal (or abstain — design question)
   - ERC-8004 `addFeedback` with `value=0` or a structured negative tag

3. **Feedback URI**
   - Currently empty — could store IPFS CID of the evaluation attestation
   - Links the on-chain feedback to the full evaluation details

---

## WAVS Component Improvements

### `component/src/evaluator.rs`

1. **Configurable evaluation logic**
   - Current: hardcoded keccak256 hash comparison
   - Better: job `description` encodes a JSON evaluation spec:
     ```json
     {
       "url": "https://httpbin.org/json",
       "eval": "hash_match",
       "options": {}
     }
     ```
   - Component parses the spec and routes to the appropriate evaluator strategy

2. **Multiple evaluation strategies**
   - `hash_match`: current behavior — keccak256 of response body
   - `schema_match`: validate response against a JSON schema
   - `contains`: check if response contains a specific string
   - `ai_eval`: call an LLM oracle to evaluate the response (advanced)
   - Each strategy produces an attestation hash that includes the strategy used

3. **HTTP response handling**
   - Currently: fetch URL, hash raw body
   - Should: handle redirects, set User-Agent, respect content-type
   - Add timeout (currently no explicit timeout on HTTP calls)
   - Handle non-200 responses as automatic reject

4. **Better attestation hash**
   - Current: `keccak256(response_body)` — just the hash of what was fetched
   - Better: `keccak256(abi.encode(jobId, url, responseHash, timestamp))` — includes context
   - Makes the attestation a commitment to the full evaluation, not just the content

5. **ERC-8128 integration (future)**
   - If the job description includes an HTTP Message Signature requirement, verify it
   - Provider proves they made a specific signed API call
   - WAVS component verifies the signature per ERC-8128 spec

---

## UI Requirements

The demo currently has no frontend. For this to be genuinely demonstrable to non-developers, we need a UI. Here's what it should do.

### Core User Flows

**As a client:**
1. Connect wallet
2. Create a job: enter description (URL), set budget, select provider address
3. Fund the job (ERC-20 approve + fund in one UX step)
4. Watch job status in real time (poll or websocket)
5. See when WAVS evaluates and the job completes or is rejected

**As a provider:**
1. Connect wallet
2. See open/funded jobs assigned to me
3. "Submit" button: auto-fetches the URL, computes hash, calls `submit(jobId, hash)`
4. Watch for completion + payout

**As an observer:**
1. Browse jobs by status
2. See WAVS evaluation timeline (submitted → evaluated → settled)
3. View provider reputation (ERC-8004 registry)

### Page Layout

```
/                    → Overview: recent jobs, stats (total locked, completed, agents)
/jobs                → Job list (filterable by status, provider, amount)
/jobs/[id]           → Job detail: full timeline, evaluation logs, attestation hash
/jobs/new            → Create job form
/providers           → Provider leaderboard (ranked by ERC-8004 reputation)
/providers/[address] → Provider profile: reputation history, completed jobs
```

### Technical Requirements

- **Framework**: Next.js + wagmi + viem (standard EVM stack)
- **Wallet**: RainbowKit or ConnectKit (support MetaMask, WalletConnect)
- **Chain support**: Localhost (Anvil), Sepolia, Base Sepolia at minimum
- **Contract addresses**: config file per chain (auto-detected from `chainId`)
- **Real-time**: poll every 5s for job status changes; show spinner while WAVS is evaluating
- **No indexer needed for v1**: direct contract reads for job list (bounded by `getJobCount()` + `getJob()` loops)

### Key UX Moments to Get Right

1. **"WAVS is evaluating..."** — after `submit()` fires, show a clear "waiting for WAVS" state. This is the magic moment. Make it feel like something is happening. Show elapsed time.

2. **Evaluation result reveal** — when `JobCompleted` or `JobRejected` event lands, animate the state change. Show the attestation hash. Link to the transaction.

3. **Reputation badge** — on provider profiles, show their ERC-8004 completion rate as a prominent badge. This is the "why this matters" moment for the reputation layer.

4. **Connect everything** — the demo URL is embedded in the job description. When viewing a job, show the URL and let the user click through to see the content being evaluated. Makes it concrete.

### What We Can Skip for v1

- Dispute UI (no dispute mechanism in current contracts)
- Multi-token support (single tUSDC for now)
- Provider registration flow (hardcode a known provider for the demo)
- Admin panel
- Search / advanced filtering

---

## Migration Plan (from wavs-examples)

### Phase 1: Extract (1-2 days)
- [ ] Create new repo `Lay3rLabs/wavs-agentic-commerce`
- [ ] Copy contracts from `wavs-examples/src/contracts/agentic-commerce/`
- [ ] Copy component from `wavs-examples/components/agentic-commerce-evaluator/`
- [ ] Copy deploy script from `wavs-examples/script/DeployAgenticCommerce.s.sol`
- [ ] Copy demo script from `wavs-examples/scripts/demo-agentic-commerce.sh`
- [ ] Set up new Foundry project (based on wavs-foundry-template structure)
- [ ] Verify `task demo` runs end-to-end on a clean machine

### Phase 2: Contract Improvements (2-3 days)
- [ ] Fix alloy workaround (or document clearly why it exists)
- [ ] Add `deliverable` to JobCompleted/JobRejected events
- [ ] Add replay protection to `AgenticCommerceEvaluator`
- [ ] Auto-lookup agentId in `ReputationHook`
- [ ] Write missing tests (`AgenticCommerceEvaluator.t.sol`)
- [ ] Gas optimize `Job` struct (descriptionHash only, full description in event)

### Phase 3: Component Improvements (2-3 days)
- [ ] Refactor into `trigger.rs` + `evaluator.rs` modules
- [ ] Improve attestation hash (include jobId + url in hash)
- [ ] Add HTTP timeout + redirect handling
- [ ] Write unit tests for evaluator logic (mock HTTP responses)

### Phase 4: UI (1-2 weeks)
- [ ] Scaffold Next.js app with wagmi
- [ ] Job list + job detail pages
- [ ] Create job form
- [ ] Provider submit flow (auto-compute hash from URL)
- [ ] Real-time job status polling
- [ ] ERC-8004 reputation display
- [ ] Deploy to Vercel (pointing at Base Sepolia)

### Phase 5: Testnet Deployment (1 day)
- [ ] Deploy contracts to Base Sepolia
- [ ] Use official ERC-8004 registries on Base Sepolia
- [ ] Update UI config with testnet addresses
- [ ] Fund demo wallets, run end-to-end on testnet
- [ ] Update README with testnet demo link

---

## Open Questions to Resolve

1. **Repo ownership**: `Lay3rLabs/wavs-agentic-commerce` or `JakeHartnell/wavs-agentic-commerce`? Layer org seems right since this is a WAVS showcase.

2. **License**: MIT? Or Apache 2.0 to match WAVS core?

3. **ERC-8004 IdentityRegistry dependency**: Should `ReputationHook` require agents to be registered? Or accept any address? For the demo it's nice to skip registration, but for production the registry is the point.

4. **Evaluation strategies**: How opinionated should we be about what kinds of jobs are supported? Keeping it to "URL hash verification" for v1 is clean. Opening it up requires spec work on the description format.

5. **Who plays provider in the UI demo?**: For a public testnet demo, we probably need a "demo provider" service that automatically fetches and submits. Otherwise the demo requires two browser tabs with two wallets. A bot provider that watches for new jobs and auto-submits would make the demo self-contained.

---

## Success Criteria

The standalone repo is done when:

- `git clone && task demo` runs a full end-to-end demo on a fresh machine in under 5 minutes
- The UI is live on testnet and a non-technical person can watch a job flow through without explanation
- The contracts have 80%+ test coverage
- The README explains ERC-8183 + WAVS in plain English before showing any code
- It's been cited or referenced in at least one ERC discussion thread

---

*Plan written 2026-03-10 · Arc ⚡*
