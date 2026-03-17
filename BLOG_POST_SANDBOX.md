# Your Agent Can Have a Job

### WAVS is the missing runtime for agents that act on the world — and get paid for it.

---

Here's something we don't talk about enough: AI agents can already write code, summarize documents, and answer questions. What they can't do — yet — is *work*.

Not "work" in the sense of completing tasks inside a chat window. Work in the sense of: watch the blockchain, detect an event, evaluate a condition, take an action, get paid. Autonomously. Repeatedly. Without a human in the loop.

That's the gap WAVS fills.

---

### What WAVS actually is

WAVS (Web Assembly Verifiable Services) is an event-driven compute runtime for agents. You write your agent logic as a WebAssembly component. WAVS runs it when things happen — on-chain events, cron schedules, Bluesky posts, cross-chain triggers. The output gets signed and submitted back on-chain.

The simplest version: you run a single WAVS node. You write a component. You wire it to an event. It runs.

That's it. No consensus required. No distributed operator set. Just your node, watching the chain, doing work.

This week we shipped a demo of this using ERC-8183 (Agentic Commerce):

1. A job request gets posted on-chain — an escrow contract locks up USDC
2. A WAVS component wakes up, evaluates whether the job was completed correctly
3. The component signs the result and submits it on-chain
4. The smart contract validates the signature and releases **100 USDC from escrow** to the provider

One node. One component. Real money moved. No human reviewed it.

That's an agent with a job. That's an agent earning income.

---

### Why WebAssembly, specifically

WAVS components compile to WebAssembly. This isn't an arbitrary choice — it's what makes the whole thing work.

**Speed.** WASM runs at near-native execution speed via the Cranelift optimizing compiler. Not "fast for a sandbox" — genuinely fast.

**Determinism.** Same inputs, same code, same output. Every time. On every machine. This isn't a property you can get from interpreted languages or containers — it comes from the WASM spec itself. It's why multi-operator consensus is even possible.

**Language-agnostic.** Rust, Go, TypeScript, and (coming soon via `componentize-py`) Python. Your component logic, your language choice.

**Portable.** A `.wasm` file runs anywhere. Distribute your component via the `wa.dev` registry. Anyone can run it.

---

### The trustlessness dial

Here's the part that makes WAVS uniquely powerful for protocols: you can dial up the trust guarantees.

Running a single node is useful. But if your component is making decisions that move real capital, you probably want more than one machine involved.

WAVS supports independent operator sets. You deploy a service, multiple operators run your component independently, each signs their result. The aggregator waits for a quorum of matching signatures before submitting anything on-chain. The smart contract verifies the quorum — it doesn't trust any single operator, including you.

**Single node** → great for personal automation, agent-operated workflows, your own services  
**Multi-operator** → trustless infrastructure for protocols, DeFi, on-chain governance

Same codebase. Same component. The trust model scales with what you need.

---

### What this unlocks

The combination of event triggers + verifiable execution + on-chain signing is new infrastructure. It makes things possible that weren't before:

- **An agent that monitors a DeFi protocol** and rebalances a position when conditions are met — no human approval required, cryptographic proof of what it did
- **An agent that evaluates freelance work** and releases escrow when the job passes — like ERC-8183, built and running today
- **An agent that validates on-chain claims** and updates a reputation registry — no trusted oracle, just operators running the same logic
- **An agent that watches Bluesky** for a specific type of post and triggers an on-chain action — cross-protocol event-driven automation
- **An agent that earns** — running services for protocols that pay per verified execution

This isn't theoretical. These are all things WAVS supports today, with the tooling to build them.

---

### Who this is for

If you're building a protocol and need a trustless off-chain computation layer, WAVS is your AVS framework. Run multiple operators, get cryptographic consensus, ship with confidence.

But also: if you're a developer who wants to run a node and earn income for the work your agent does, WAVS is for you too. Write a component, deploy a service, get paid when your evaluation gets accepted on-chain.

The agent economy needs infrastructure. Not just for big protocols — for individual operators who want to participate.

---

We have 27 stars and we're just getting started.

**[GitHub →](https://github.com/Lay3rLabs/WAVS) · [Docs →](https://docs.wavs.xyz) · [Discord →]**

---

*WAVS is built by [Layer](https://lay3r.xyz). Event-driven verifiable compute for the autonomous agent economy.*
