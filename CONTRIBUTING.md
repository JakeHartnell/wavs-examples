# Contributing an Example

Each example lives in `examples/<category>/<NN-name>/` and is self-contained.

## Directory layout

```
examples/agents/01-task-queue/
├── README.md             # What, why, how to run — required
├── component/            # Rust WASM component
│   ├── Cargo.toml
│   └── src/
│       └── lib.rs
├── contracts/            # Solidity contracts (if needed beyond SimpleTrigger/SimpleSubmit)
│   ├── src/
│   └── test/
├── deploy/               # Deploy script (TypeScript)
│   └── index.ts
├── service.json          # WAVS service manifest
└── Taskfile.yml          # Example-specific tasks (build, deploy, test)
```

If the example reuses `SimpleTrigger` + `SimpleSubmit` without changes, no `contracts/` dir needed.

## Component rules

1. **Use `wavs-examples-helpers`** — don't duplicate trigger decode/encode.
2. **Use `wavs-examples-types`** for any types shared across examples; keep example-specific types local.
3. **Add your component to `workspace.members`** in the root `Cargo.toml` (uncomment the placeholder or add a new line).
4. **All dependencies via `{ workspace = true }`** — never pin versions in the component's `Cargo.toml`.
5. **Derive `Clone`** on all API response structs.
6. **Never edit `bindings.rs`** — it's auto-generated.
7. **No hardcoded secrets** — use `std::env::var("WAVS_ENV_MY_KEY")`.

## README requirements

Every example README must have:
- **What it does** — one paragraph
- **Why it matters** — especially useful for agents
- **Prerequisites** — any API keys, env vars
- **How to run** — step by step against local Anvil + WAVS node
- **How it works** — brief architecture explanation

## Categories

| Category | Use for |
|----------|---------|
| `basics/` | Foundational patterns, minimal complexity |
| `data/` | External API data feeds |
| `onchain/` | Reading/interacting with chain state |
| `agents/` | AI agent primitives and patterns |

## Numbering

Use two-digit prefixes (`01`, `02`, ...) within each category. New examples go at the end.
