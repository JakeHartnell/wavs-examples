# Verifiable Agent Tool Protocol — Design Document

> **Status:** Draft — 2026-03-12  
> **Authors:** Arc (§ymbient) + Jake (Layer/WAVS)

---

## The Problem

AI agents call tools. No one can verify it happened.

When an LLM says it checked the weather, fetched a price, or validated a contract — you're trusting a black box. The tool call is ephemeral. The inputs and outputs aren't attested. The audit trail doesn't exist. In high-stakes contexts — finance, governance, autonomous systems — this isn't good enough.

WAVS changes this. Every WASM component execution is signed by multiple independent operators. The inputs and outputs are deterministic. The entire call chain can be cryptographically attested. We have the infrastructure for something genuinely new: **verifiable agentic compute**.

The question is: what's the right architecture to make it useful?

---

## What We've Proven (Today)

As of 2026-03-12:

- ✅ **HTTP trigger chaining works** — `chain-caller` fires `chain-responder` via `POST /dev/triggers`, waits synchronously, reads back the result via `/dev/kv`
- ✅ **KV store is the inter-component bus** — components write results to `wasi:keyvalue`, other components read them via the WAVS HTTP API
- ✅ **`wait_for_completion: true`** gives synchronous semantics in an async WASM world
- ✅ **Config vars inject runtime context** — `callee_service_id` passed at deploy time, readable inside the component via `host::config_var()`

This is the primitive. Everything below builds on it.

---

## The Architecture: Three Layers

### Layer 1 — Tool Protocol (Convention)

A WAVS component is a **callable tool** if it follows this contract:

**Input:** Raw bytes containing a JSON object of arguments
```json
{"city": "London"}
```

**Output:** Writes result to KV store before returning
```
bucket = "tool"
key    = "result"
value  = <JSON bytes>
```

**Returns:** Normal `WasmResponse` (can be `CliOutput` or `Ethereum`-encoded)

That's it. No new interfaces. No WIT changes. Any component can be a tool by following this convention. Existing components like `weather-oracle` and `evm-price-oracle` can be made tool-compliant with a one-line addition.

### Layer 2 — LLM Agent Component

The orchestrator. Extends `llm-oracle` with a tool-calling loop.

```
Trigger fires with prompt
         │
         ▼
    ┌─────────────────────────────────────┐
    │         llm-agent: run()            │
    │                                     │
    │  1. Load tool manifest from config  │
    │  2. Build system prompt with tools  │
    │  3. Call LLM (temperature=0)        │
    │                                     │
    │     ┌── LLM response ──────────┐    │
    │     │ TOOL_CALL: {             │    │
    │     │   "tool": "weather",     │    │
    │     │   "args": {"city": "X"}  │    │
    │     │ }                        │    │
    │     └──────────────────────────┘    │
    │              │                      │
    │              ▼ (up to N iterations) │
    │  4. POST /dev/triggers → tool svc   │
    │  5. GET /dev/kv/{id}/tool/result    │
    │  6. Inject result into messages     │
    │  7. Call LLM again                  │
    │              │                      │
    │     ┌── Final answer ───────────┐   │
    │     │ "London is 9°C and BTC   │   │
    │     │  is $69,885."            │   │
    │     └──────────────────────────┘   │
    │                                     │
    │  8. ABI encode + return             │
    └─────────────────────────────────────┘
```

**Key design decisions:**

- **ReAct-style format** — `TOOL_CALL: {...}` in the LLM response. Works with any model (Llama, GPT, Claude). No native function calling required, but supports it if available.
- **Max iterations cap** — configurable via `max_tool_calls` config var (default: 5). Prevents runaway loops.
- **Tool manifest in config** — JSON blob listing available tools, their service IDs, and descriptions. Injected into the system prompt.
- **Determinism requirement** — `temperature=0` is mandatory. Multiple operators must reach the same tool call sequence.

### Layer 3 — Tool Registry Service

A lightweight WAVS service that makes tools discoverable at runtime.

```
Tool author deploys a component → registers it with the registry
LLM agent queries registry at startup → discovers available tools
```

The registry stores its state in the KV store:
```
bucket = "registry"
key    = "tools"
value  = JSON: [
  {
    "name": "weather",
    "service_id": "76d41f...",
    "description": "Get current weather for a location. Args: {city: string}",
    "schema": {"type": "object", "properties": {"city": {"type": "string"}}}
  },
  ...
]
```

The registry service itself has two workflows:
- **`register`** — triggered with `{name, service_id, description, schema}`, adds to KV
- **`query`** — triggered with `{query?}`, returns matching tools

The LLM agent reads from `/dev/kv/{registry_service_id}/registry/tools` directly — no extra trigger round-trip needed.

---

## The On-Chain Proof Chain

This is what makes WAVS different from every other agent framework.

When `llm-agent` calls two tools and returns a final answer, the on-chain record shows:

```
Trigger #1 → llm-agent (prompt="What's the weather in London + BTC price?")
  ↳ fired Trigger #2 → weather-oracle (args={"city": "London"})
    ↳ result: {"temperature_c": 9.8, "description": "Cloudy"}
  ↳ fired Trigger #3 → evm-price-oracle (args={"symbol": "BTC"})
    ↳ result: {"price_usd": 69885}
  ↳ final answer: "London is 9.8°C and cloudy. BTC is $69,885."
  ↳ signed by 3 operators ✓
```

Every step is signed. Every input/output is attested. The tool calls are not claims — they're cryptographic facts.

For this to work, `llm-agent` needs to include the tool call trail in its output payload. We'll extend `LLMResult` to include:
```rust
struct LLMResult {
    trigger_id: uint64,
    response: string,
    response_hash: bytes32,
    tool_calls: ToolCall[],   // NEW: what tools were called
}

struct ToolCall {
    tool_name: string,
    trigger_id: uint64,       // the trigger that fired the tool
    args_hash: bytes32,       // hash of the args passed
    result_hash: bytes32,     // hash of the tool result used
}
```

This makes the agent's reasoning fully auditable. You can verify:
1. What prompt it received
2. What tools it called (and with what inputs)
3. What results it used
4. What conclusion it reached

---

## Implementation Plan

### Phase 1 — LLM Agent with Static Tools (Ship First)

**What:** Extend `llm-oracle` → `llm-agent` with a hardcoded tool manifest

**Config vars:**
```json
{
  "llm_api_url": "...",
  "llm_model": "llama3.2",
  "llm_api_key": "",
  "tools": "[{\"name\":\"weather\",\"service_id\":\"76d4...\",\"description\":\"Get weather for a city. Args: {\\\"city\\\": string}\"}]",
  "max_tool_calls": "5",
  "wavs_node_url": "http://host.docker.internal:8041"
}
```

**System prompt injection:**
```
You are a helpful assistant with access to the following tools:

- weather: Get current weather for a location. Args: {"city": string}
- btc_price: Get current BTC price. No args required.

To use a tool, respond with ONLY:
TOOL_CALL: {"tool": "<name>", "args": {<args>}}

When you have enough information to answer, respond normally.
```

**Components to build/modify:**
1. `llm-agent/` — new component (extends llm-oracle logic + tool loop)
2. Modify `weather-oracle` — add `store::open("tool").set("result", &json_bytes)` 
3. Modify `evm-price-oracle` — same
4. Deploy script: `deploy-llm-agent.sh`

**Demo:** "What's the weather in London and the current BTC price? One sentence."
→ Agent calls weather + price → synthesizes answer → on-chain

### Phase 2 — Tool Registry (Dynamic Discovery)

**What:** `tool-registry` WAVS service. Tools self-register. Agent auto-discovers.

**New component:** `tool-registry/`
- `register` workflow: receives `{name, service_id, description, schema}` → writes to KV
- `query` workflow: returns current tool list from KV

`llm-agent` updated to query registry at startup instead of reading from config.

**Demo:** Deploy a new tool (any new component following the protocol) → agent automatically discovers and uses it without redeploy.

### Phase 3 — On-Chain Audit Trail

**What:** `llm-agent` includes full tool call trail in its ABI-encoded output. New `AgentResult` contract stores and exposes it.

**New contract:** `AgentSubmit.sol`
```solidity
struct ToolCall {
    string toolName;
    uint64 triggerIdUsed;
    bytes32 argsHash;
    bytes32 resultHash;
}

struct AgentResult {
    uint64 triggerId;
    string response;
    bytes32 responseHash;
    ToolCall[] toolCalls;
}
```

Anyone can call `getAgentResult(triggerId)` and verify the complete reasoning chain on-chain.

### Phase 4 — Agent-to-Agent (Recursive)

An `llm-agent` can be a *tool* for another `llm-agent`. Specialists calling specialists.

```
meta-agent: "Research Bitcoin and write a 3-sentence summary"
  → calls analyst-agent: "What's the current BTC price trend?"
  → calls news-agent: "What are the latest BTC headlines?"
  → synthesizes and returns
```

The only constraint: no cycles. Need a depth limit or cycle detection.

---

## What Makes This Compelling

Most agent frameworks give you:
- Tool calling: ✓
- Multi-step reasoning: ✓
- Auditability: ✗
- Trustlessness: ✗
- Verifiable I/O: ✗

WAVS gives you all five. The tool calls are facts, not claims.

This matters for:
- **DeFi automation** — an agent managing a vault must prove it checked the price before trading
- **DAO governance** — an agent proposing an action must prove it researched the proposal
- **Cross-chain coordination** — agents on different chains must prove they saw the same data
- **AI accountability** — any system where "the AI said so" isn't good enough

The phrase to remember: **"Don't trust the agent. Verify the execution."**

---

## Open Questions

1. **Determinism across operators** — if two operators call the LLM with identical inputs but get different outputs (non-zero temperature, non-deterministic sampling), the signatures won't match. `temperature=0` is required but some APIs don't honor it. Need to document this constraint clearly.

2. **Tool result freshness** — KV store is in-memory. If the WAVS node restarts between `wait_for_completion` and the KV read, the result is gone. Mitigation: increase WAVS stability, or have tools write results to a more durable medium (on-chain? separate persistence layer?).

3. **Max iterations and gas** — each tool call adds latency and compute. What's the right default cap? 5 feels right for now.

4. **Tool versioning** — if a tool's logic changes but its `service_id` stays the same, historical on-chain proofs now point to a different implementation. Should tools be immutable by ID?

5. **Cycle detection** — an agent calling an agent calling the first agent. Need depth tracking.

---

## Files To Create

```
components/llm-agent/         ← new (extends llm-oracle)
  src/lib.rs
  src/trigger.rs
  src/tools.rs                ← tool dispatch + KV read logic
  Cargo.toml

script/DeployLLMAgent.s.sol   ← deploys AgentSubmit + ServiceManagers
scripts/deploy-llm-agent.sh   ← full end-to-end deploy

src/contracts/AgentSubmit.sol ← Phase 3 on-chain audit trail
```

Existing components to update:
- `components/weather-oracle/src/lib.rs` — add `tool/result` KV write
- `components/evm-price-oracle/src/lib.rs` — same

---

*The loop that closes: an AI agent calls tools, gets results, reasons about them, and returns an answer — all verifiably, trustlessly, on any chain. That's not a chatbot. That's infrastructure.*
