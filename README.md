# wavs-examples

A collection of examples for [WAVS](https://github.com/Lay3rLabs/WAVS) — the WebAssembly Verifiable Services framework for event-driven decentralized applications.

## What's here

Each example is a self-contained WAVS service: a Rust/WASM component, optional Solidity contracts, a service manifest, and a README explaining what it does and why.

### Structure

```
examples/
├── basics/               # Start here
│   ├── 01-echo/          # Simplest possible component: echo trigger data back
│   └── 02-price-oracle/  # Adapted from the WAVS foundry template
│
├── data/                 # Real-world data feeds
│   ├── 01-weather/       # Historical weather data oracle
│   └── 02-sports/        # Sports results oracle
│
├── onchain/              # Blockchain interactions
│   ├── 01-token-balance/ # ERC-20 balance checker
│   └── 02-nft-ownership/ # NFT ownership verifier
│
└── agents/               # 🤖 AI agent primitives built on WAVS
    ├── 01-task-queue/    # On-chain task queue for agent workflows
    ├── 02-agent-memory/  # Verifiable persistent memory for agents
    ├── 03-ai-inference/  # Deterministic on-chain AI inference (Ollama)
    ├── 04-agent-watcher/ # Autonomous agent monitoring + alerts
    └── 05-multi-agent/   # Chained workflows between agents
```

### Shared infrastructure

```
components/
├── _helpers/  # Shared Rust crate: trigger decode/encode, WIT bindings
└── _types/    # Shared data types used across examples
```

## Prerequisites

- [Rust](https://www.rust-lang.org/tools/install) + `wasm32-wasip2` target
- [cargo-component](https://github.com/bytecodealliance/cargo-component)
- [Foundry](https://book.getfoundry.sh/)
- [Docker](https://docs.docker.com/get-started/get-docker/) (for running the local WAVS node)
- [Task](https://taskfile.dev/installation/) (`npm install -g @go-task/cli`)

```bash
# Install Rust toolchain
rustup target add wasm32-wasip2

# Install cargo tooling
cargo install cargo-binstall
cargo binstall cargo-component wasm-tools warg-cli wkg --locked --no-confirm --force

# Configure default registry
wkg config --default-registry wa.dev
```

## Quick start

```bash
# Start local WAVS node + Anvil
task start-all-local

# Run a specific example (see each example's README)
cd examples/basics/01-echo
task deploy
```

## LLM Agent

The `components/llm-agent/` directory contains a production-ready **Verifiable Agent Tool Protocol (VATP)** implementation: a WASM component that runs a ReAct-style reasoning loop, calls other WAVS services as tools, and commits every tool invocation on-chain as a cryptographic audit trail.

**What makes it different from a regular LLM wrapper:**
- Tool calls are dispatched to other *verifiable* WAVS services — not raw HTTP endpoints
- Every tool call records `keccak256(args)` + `keccak256(result)` on-chain via `AgentSubmit`
- Works with Ollama (local), OpenAI, Anthropic, or any OpenAI-compatible provider
- One-command demo deploys a weather oracle + crypto price oracle as tools

```bash
# Start local stack, then run the full demo:
task start-all-local
./scripts/deploy-llm-agent.sh

# With a cloud LLM:
LLM_API_KEY=sk-ant-... LLM_API_URL=https://api.anthropic.com LLM_MODEL=claude-opus-4-5 \
  ./scripts/deploy-llm-agent.sh
```

See [`components/llm-agent/README.md`](components/llm-agent/README.md) for the full tool protocol spec, config reference, and on-chain audit trail documentation.

## The agent angle

WAVS is uniquely powerful for AI agents. Think about what an agent normally lacks:

- **Persistent, verifiable memory** — not just local files, but state committed on-chain
- **Event-driven autonomy** — reacting to on-chain events without being polled
- **Verifiable outputs** — cryptographic proof that a specific computation ran
- **Multi-agent coordination** — passing work between agents through on-chain state

The `examples/agents/` directory explores all of these primitives. If you're building AI agent infrastructure, start there.

## Adding an example

See [CONTRIBUTING.md](./CONTRIBUTING.md).

## Resources

- [WAVS Docs](https://docs.wavs.xyz)
- [WAVS GitHub](https://github.com/Lay3rLabs/WAVS)
- [Foundry Template](https://github.com/Lay3rLabs/wavs-foundry-template)
- [awesome-WAVS](https://github.com/Lay3rLabs/awesome-WAVS)
