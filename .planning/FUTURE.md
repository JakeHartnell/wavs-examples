# Future Roadmap — Verifiable Agent Tool Protocol (VATP)

Remaining phases for the VATP implementation beyond what ships in the initial demo.

---

## Phase 2: Tool Registry Component

**Goal:** Replace the static tool manifest in agent config with a dynamic on-chain registry.

**What this enables:**
- Agents discover tools at runtime rather than requiring redeploy to add tools
- Tool versioning: registry stores component digest + semver
- Tool metadata on-chain: description, arg schema, pricing

**Deliverables:**
- `components/tool-registry/` — WASM component that reads from an on-chain `ToolRegistry` contract
- `src/contracts/ToolRegistry.sol` — mapping of `toolName => (serviceId, digest, description)`
- Update `llm-agent` to fetch tool manifest from registry service instead of config var
- `scripts/register-tool.sh` — register any WAVS service as a tool

---

## Phase 4: Agent-to-Agent with Depth Tracking

**Goal:** Allow the `llm-agent` to use *another* `llm-agent` as a tool, with cycle detection and recursion depth limits enforced on-chain.

**What this enables:**
- Hierarchical agent decomposition (planner → executor agents)
- Parallel sub-agent invocation patterns
- Multi-agent pipelines where outputs feed into subsequent agents

**Deliverables:**
- Extend `AgentResult` with `uint8 depth` and `bytes32 parentTriggerId`
- `AgentSubmit.sol` enforces `depth <= MAX_DEPTH` on submission
- `llm-agent` propagates depth counter when dispatching to child agents
- Integration test: 2-level agent chain with depth enforcement

---

## ERC-8183 + Agent Tools Integration

**Goal:** Align the VATP tool manifest format with the emerging ERC-8183 agent tools standard, making WAVS tools composable with the broader EVM agent ecosystem.

**Context:**
- ERC-8183 proposes a standard interface for on-chain tool registration and invocation
- WAVS tools currently use a custom JSON format that could be a conforming ERC-8183 implementation
- Alignment enables WAVS tool components to be discovered and used by non-WAVS EVM agents

**Deliverables:**
- Review ERC-8183 draft against current VATP tool manifest schema
- `src/contracts/ToolRegistry.sol` implements ERC-8183 interface
- Update `ToolDef` in `llm-agent/src/lib.rs` to match ERC-8183 field names
- Write a compatibility shim for existing deployed tool services

---

## Notes

- Phase 3 (on-chain tool call audit trail) is **complete** — ships in the initial demo via `AgentSubmit.sol`
- Phases above are prioritized but not scheduled; pick them up as separate milestones
- Phase 2 is the most impactful short-term improvement (removes the main friction point for adding new tools)
