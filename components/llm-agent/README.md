# llm-agent

A WAVS component that implements the **Verifiable Agent Tool Protocol (VATP)** — a ReAct-style reasoning loop where an LLM can call other WAVS services as tools, with every tool invocation recorded on-chain as a cryptographic fact.

## What it does

1. Receives a prompt via on-chain trigger (`addTrigger(string)`)
2. Calls an LLM with the prompt and a tool manifest
3. If the LLM responds with `TOOL_CALL: {...}`, dispatches the call to another WAVS service
4. Feeds the result back to the LLM and loops
5. When the LLM gives a final answer, ABI-encodes the result — including a `ToolCall[]` audit trail — and submits it on-chain via `AgentSubmit`

The result stored on-chain includes:
- The final response text
- `keccak256` of the response (tamper-evident)
- `ToolCall[]`: for every tool invoked, the tool name + `keccak256(args)` + `keccak256(result)`

## Supported LLM providers

| Provider | `llm_api_url` | `llm_api_key` |
|---|---|---|
| Ollama (local) | `http://host.docker.internal:11434` | _(not set)_ |
| OpenAI | `https://api.openai.com` | `sk-...` |
| Anthropic | `https://api.anthropic.com` | `sk-ant-...` |
| Any OpenAI-compatible | custom URL | set any value |

## Config vars

Set these in your service manifest under `workflows.default.component.config`:

| Key | Default | Description |
|---|---|---|
| `llm_api_url` | `http://host.docker.internal:11434` | LLM API base URL |
| `llm_model` | `llama3.2` | Model name (e.g. `gpt-4o`, `claude-opus-4-5`) |
| `llm_api_key` | _(not set)_ | API key; if set, uses OpenAI-compatible auth (or Anthropic if URL contains `anthropic.com`) |
| `tools` | `[]` | JSON array of tool definitions (see below) |
| `max_tool_calls` | `5` | Maximum tool calls per request before returning an error |
| `wavs_node_url` | `http://localhost:8041` | WAVS REST API URL — used internally to dispatch tool calls |

## Tool protocol

Any WAVS component can be a tool. The agent calls it by firing a manual trigger via the WAVS REST API (`POST /dev/triggers`) and reads the result from the KV store at `{service_id}/tool/result`.

**To make a component a tool**, write your output to the WAVS KV store:

```rust
// In your component's run() function:
host::kv_set("tool", "result", &result_json.as_bytes());
```

The value should be a UTF-8 string (typically JSON) that the LLM will see as the tool result.

### Tool manifest format

Pass a JSON array as the `tools` config var:

```json
[
  {
    "name": "weather",
    "service_id": "a1b2c3d4...",
    "description": "Get current weather for a city. Args: {\"city\": string}",
    "workflow_id": "default"
  },
  {
    "name": "crypto_price",
    "service_id": "e5f6a7b8...",
    "description": "Get current cryptocurrency price in USD. Args: {\"symbol\": string} e.g. BTC, ETH, SOL",
    "workflow_id": "default"
  }
]
```

| Field | Required | Description |
|---|---|---|
| `name` | yes | Short identifier the LLM uses in `TOOL_CALL` |
| `service_id` | yes | WAVS service ID of the deployed tool component |
| `description` | yes | Injected into the system prompt so the LLM knows when/how to use the tool |
| `workflow_id` | no | Defaults to `"default"` |

### TOOL_CALL format

When the LLM wants to call a tool, it responds with exactly:

```
TOOL_CALL: {"tool": "<name>", "args": {<json arguments>}}
```

The component parses the first `TOOL_CALL:` line per iteration, dispatches it, and feeds the result back as a user message before continuing the loop.

## On-chain audit trail

Every tool call is recorded on-chain via `AgentSubmit`:

```solidity
struct ToolCall {
    string toolName;
    bytes32 argsHash;   // keccak256(JSON args string)
    bytes32 resultHash; // keccak256(JSON result string)
}
```

Query the proof chain after a run:

```bash
cast call $AGENT_SUBMIT \
  "getToolCalls(uint64)((string,bytes32,bytes32)[])" 1 \
  --rpc-url http://localhost:8545
```

## Quick start

```bash
# Start local stack (Anvil + WAVS node + IPFS)
task start-all-local

# Deploy everything and run a demo prompt
./scripts/deploy-llm-agent.sh

# Use a cloud LLM instead of local Ollama
LLM_API_KEY=sk-ant-... \
LLM_API_URL=https://api.anthropic.com \
LLM_MODEL=claude-opus-4-5 \
./scripts/deploy-llm-agent.sh
```

## Build

```bash
WASI_BUILD_DIR=components/llm-agent task build:wasi
# or
cargo component build --release -p llm-agent --target wasm32-wasip1
```
