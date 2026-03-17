#!/usr/bin/env bash
# =============================================================================
# deploy-llm-agent.sh — Deploy and test the verifiable agent tool protocol
#
# Deploys TWO services:
#   1. agent-tools  — two workflows: "weather" + "crypto_price"
#                     (shared service manager, one signing key)
#   2. llm-agent    — orchestrator: ReAct loop calling the above tools
#
# Requires:
#   - Anvil running at $RPC_URL           (default: http://localhost:8545)
#   - WAVS node at $WAVS_URL              (default: http://localhost:8041)
#   - LLM accessible via $LLM_API_URL
#   - forge, cast, cargo-component in PATH
#
# Config:
#   LLM_API_URL   — default: http://localhost:11434  (Ollama on wavs-app / native)
#   LLM_MODEL     — default: llama3.2
#   LLM_API_KEY   — if set: switches to OpenAI-compatible or Anthropic mode
#   PROMPT        — default: "What is the current weather in London and the BTC price?"
#
# Usage:
#   ./scripts/deploy-llm-agent.sh
#   LLM_API_KEY=sk-ant-... LLM_API_URL=https://api.anthropic.com LLM_MODEL=claude-opus-4-5 ./scripts/deploy-llm-agent.sh
#   LLM_API_KEY=sk-...     LLM_API_URL=https://api.openai.com    LLM_MODEL=gpt-4o ./scripts/deploy-llm-agent.sh
#   PROMPT="What's the ETH price?" ./scripts/deploy-llm-agent.sh
# =============================================================================
set -euo pipefail

RPC_URL="${RPC_URL:-http://localhost:8545}"
WAVS_URL="${WAVS_URL:-http://localhost:8041}"
CHAIN_ID="${CHAIN_ID:-evm:31337}"
PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

# LLM config
# NOTE: wavs-app runs WASM natively (not in Docker), so Ollama is at localhost.
#       If running inside Docker, change to http://host.docker.internal:11434
LLM_API_URL="${LLM_API_URL:-http://localhost:11434}"
LLM_MODEL="${LLM_MODEL:-llama3.2}"
LLM_API_KEY="${LLM_API_KEY:-}"
PROMPT="${PROMPT:-What is the current weather in London and the current price of BTC? Answer in two sentences.}"

# WAVS REST URL that the WASM component uses to dispatch tool calls.
WAVS_INTERNAL_URL="${WAVS_INTERNAL_URL:-http://localhost:8041}"

GREEN="\033[0;32m"; BLUE="\033[0;34m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; NC="\033[0m"
info()    { echo -e "${BLUE}▶ $*${NC}"; }
success() { echo -e "${GREEN}✅ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
die()     { echo -e "${RED}❌ $*${NC}"; exit 1; }

extract() {
  local resp="$1" field="$2"
  python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d$field)
except Exception:
    print('', end='')
    sys.exit(1)
" "$resp"
}

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          Verifiable Agent Tool Protocol — Deploy             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  RPC:    $RPC_URL"
echo "  WAVS:   $WAVS_URL"
echo "  LLM:    $LLM_API_URL  (model: $LLM_MODEL)"
echo "  Prompt: $PROMPT"
echo ""

# =============================================================================
# 0. Pre-flight checks
# =============================================================================
info "Running pre-flight checks..."

if ! curl -sf --connect-timeout 3 -X POST "$RPC_URL" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    > /dev/null 2>&1; then
  die "Anvil is not reachable at $RPC_URL\n\n  Start the local stack first:\n    task start-all-local"
fi
success "Anvil reachable at $RPC_URL"

if ! curl -sf --connect-timeout 3 "$WAVS_URL/services" > /dev/null 2>&1; then
  die "WAVS node is not reachable at $WAVS_URL\n\n  Start the local stack first:\n    task start-all-local"
fi
success "WAVS node reachable at $WAVS_URL"

echo ""

# =============================================================================
# 1. Clean up any previously registered services from prior runs
# =============================================================================
info "Cleaning up stale services from previous runs..."

STALE_IDS=$(curl -s "$WAVS_URL/services" | python3 -c "
import json, sys
d = json.load(sys.stdin)
services = d.get('services', [])
ids = d.get('service_ids', [])
target_names = {'weather-oracle', 'crypto-price', 'agent-tools', 'llm-agent'}
for svc, sid in zip(services, ids):
    if svc.get('name') in target_names:
        print(sid)
" 2>/dev/null || true)

if [ -n "$STALE_IDS" ]; then
  while IFS= read -r sid; do
    [ -z "$sid" ] && continue
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$WAVS_URL/services/$sid" 2>/dev/null) || true
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
      echo "  Removed stale service: ${sid:0:16}..."
    else
      warn "  Could not remove ${sid:0:16}... (HTTP $HTTP_CODE) — continuing anyway"
    fi
  done <<< "$STALE_IDS"
  success "Stale services cleaned up"
else
  echo "  No stale services found"
fi

echo ""

# =============================================================================
# 2. Build all WASM components
# =============================================================================
info "Building WASM components..."
cargo component build --release \
  -p weather-oracle \
  -p crypto-price \
  -p llm-agent \
  -p aggregator \
  --target wasm32-wasip1 \
  2>&1 | grep -E "^error|Compiling|Finished|Creating" | tail -20

WEATHER_WASM="target/wasm32-wasip1/release/weather_oracle.wasm"
CRYPTO_WASM="target/wasm32-wasip1/release/crypto_price.wasm"
AGENT_WASM="target/wasm32-wasip1/release/llm_agent.wasm"
AGG_WASM="target/wasm32-wasip1/release/aggregator.wasm"

for f in "$WEATHER_WASM" "$CRYPTO_WASM" "$AGENT_WASM" "$AGG_WASM"; do
  [ -f "$f" ] || die "Missing: $f"
done
success "All components built"

# =============================================================================
# 3. Deploy contracts
#    - DeployTools.s.sol   → ONE service manager + 2 triggers + 2 SimpleSubmit
#    - DeployLLMOracle.s.sol → agent trigger + agent SM + AgentSubmit
# =============================================================================
info "Deploying contracts (tools + agent)..."

run_forge() {
  local script="$1"
  forge script "$script" \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --private-key "$PRIVATE_KEY" \
    2>&1
}

# Tools contracts (shared SM for weather + crypto workflows)
TOOLS_OUT=$(run_forge script/DeployTools.s.sol)
TOOLS_SM=$(echo "$TOOLS_OUT"       | grep "TOOLS_SM_ADDR="        | tail -1 | cut -d= -f2 | tr -d ' \r')
WEATHER_TRIGGER=$(echo "$TOOLS_OUT" | grep "WEATHER_TRIGGER_ADDR=" | tail -1 | cut -d= -f2 | tr -d ' \r')
WEATHER_SUBMIT=$(echo "$TOOLS_OUT"  | grep "WEATHER_SUBMIT_ADDR="  | tail -1 | cut -d= -f2 | tr -d ' \r')
CRYPTO_TRIGGER=$(echo "$TOOLS_OUT"  | grep "CRYPTO_TRIGGER_ADDR="  | tail -1 | cut -d= -f2 | tr -d ' \r')
CRYPTO_SUBMIT=$(echo "$TOOLS_OUT"   | grep "CRYPTO_SUBMIT_ADDR="   | tail -1 | cut -d= -f2 | tr -d ' \r')
[ -n "$TOOLS_SM" ] || { echo "$TOOLS_OUT" >&2; die "No TOOLS_SM_ADDR in forge output"; }

# Agent contracts
AGENT_OUT=$(run_forge script/DeployLLMOracle.s.sol)
AGENT_TRIGGER=$(echo "$AGENT_OUT" | grep "TRIGGER_ADDR="         | tail -1 | cut -d= -f2 | tr -d ' \r')
AGENT_SM=$(echo "$AGENT_OUT"      | grep "SERVICE_MANAGER_ADDR=" | tail -1 | cut -d= -f2 | tr -d ' \r')
AGENT_SUBMIT=$(echo "$AGENT_OUT"  | grep "AGENT_SUBMIT_ADDR="    | tail -1 | cut -d= -f2 | tr -d ' \r')
[ -n "$AGENT_TRIGGER" ] || { echo "$AGENT_OUT" >&2; die "No TRIGGER_ADDR in forge output"; }

success "Contracts deployed"
echo "  Tools SM:        $TOOLS_SM"
echo "  Weather trigger: $WEATHER_TRIGGER  submit: $WEATHER_SUBMIT"
echo "  Crypto trigger:  $CRYPTO_TRIGGER   submit: $CRYPTO_SUBMIT"
echo "  Agent trigger:   $AGENT_TRIGGER    sm: $AGENT_SM    submit: $AGENT_SUBMIT"

EVENT_HASH=$(cast keccak "NewTrigger(bytes)")

# =============================================================================
# 4. Upload WASM components to WAVS node
# =============================================================================
info "Uploading components to WAVS node at $WAVS_URL..."

upload_component() {
  local name="$1" wasm_path="$2"
  local resp digest
  resp=$(curl -s -X POST "$WAVS_URL/dev/components" \
    -H "Content-Type: application/wasm" \
    --data-binary @"$wasm_path")
  digest=$(extract "$resp" "['digest']") || true
  if [ -z "$digest" ]; then
    echo "  Raw response: $resp" >&2
    die "Failed to upload $name — empty digest"
  fi
  echo "$digest"
}

WEATHER_DIGEST=$(upload_component weather-oracle "$WEATHER_WASM")
success "weather-oracle: $WEATHER_DIGEST"

CRYPTO_DIGEST=$(upload_component crypto-price "$CRYPTO_WASM")
success "crypto-price:   $CRYPTO_DIGEST"

AGENT_DIGEST=$(upload_component llm-agent "$AGENT_WASM")
success "llm-agent:      $AGENT_DIGEST"

AGG_DIGEST=$(upload_component aggregator "$AGG_WASM")
success "aggregator:     $AGG_DIGEST"

# =============================================================================
# 5. Register agent-tools service (two workflows: weather + crypto_price)
# =============================================================================
TMPDIR_DEPLOY=$(mktemp -d)
trap "rm -rf $TMPDIR_DEPLOY" EXIT

info "Registering agent-tools service (weather + crypto_price workflows)..."

python3 - "$TOOLS_SM" \
           "$WEATHER_TRIGGER" "$WEATHER_DIGEST" "$WEATHER_SUBMIT" \
           "$CRYPTO_TRIGGER"  "$CRYPTO_DIGEST"  "$CRYPTO_SUBMIT"  \
           "$AGG_DIGEST" "$EVENT_HASH" "$CHAIN_ID" \
           "$TMPDIR_DEPLOY/tools-service.json" << 'PYEOF'
import json, sys
sm, wt, wd, ws, ct, crd, cs, agg, event_hash, chain_id, out_file = sys.argv[1:]

def workflow(trigger_addr, comp_digest, submit_addr, comp_config=None):
    return {
        "trigger": {
            "evm_contract_event": {
                "chain": chain_id,
                "address": trigger_addr,
                "event_hash": event_hash
            }
        },
        "component": {
            "source": {"digest": comp_digest},
            "permissions": {
                "allowed_http_hosts": "all",
                "file_system": False,
                "raw_sockets": False,
                "dns_resolution": True
            },
            "env_keys": [],
            "config": comp_config or {},
            "time_limit_seconds": 300
        },
        "submit": {
            "aggregator": {
                "component": {
                    "source": {"digest": agg},
                    "permissions": {
                        "allowed_http_hosts": "none",
                        "file_system": False,
                        "raw_sockets": False,
                        "dns_resolution": False
                    },
                    "env_keys": [],
                    "config": {chain_id: submit_addr}
                },
                "signature_kind": {"algorithm": "secp256k1", "prefix": "eip191"}
            }
        }
    }

svc = {
    "name": "agent-tools",
    "status": "active",
    "manager": {"evm": {"chain": chain_id, "address": sm}},
    "workflows": {
        "weather":      workflow(wt, wd, ws),
        "crypto_price": workflow(ct, crd, cs)
    }
}
with open(out_file, 'w') as f:
    json.dump(svc, f, indent=2)
PYEOF

# POST service definition
TOOLS_RESP=$(curl -s -X POST "$WAVS_URL/dev/services" \
  -H "Content-Type: application/json" \
  -d @"$TMPDIR_DEPLOY/tools-service.json")
TOOLS_HASH=$(extract "$TOOLS_RESP" "['hash']") || true
[ -n "$TOOLS_HASH" ] || { echo "  Raw: $TOOLS_RESP" >&2; die "Failed to save agent-tools service"; }

# Set URI on-chain
TOOLS_URI="http://127.0.0.1:8041/dev/services/$TOOLS_HASH"
cast send "$TOOLS_SM" "setServiceURI(string)" "$TOOLS_URI" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet >/dev/null 2>&1

# Register with WAVS node
TOOLS_REG=$(curl -s -X POST "$WAVS_URL/services" \
  -H "Content-Type: application/json" \
  -d "{\"service_manager\":{\"evm\":{\"chain\":\"$CHAIN_ID\",\"address\":\"$TOOLS_SM\"}}}")

TOOLS_SVC_ID=$(echo "$TOOLS_REG" | python3 -c "import json,sys; print(json.load(sys.stdin)['service_id'])" 2>/dev/null) || true

if [ -z "$TOOLS_SVC_ID" ]; then
  attempts=0
  while [ -z "$TOOLS_SVC_ID" ] && [ $attempts -lt 20 ]; do
    sleep 1; attempts=$((attempts + 1))
    TOOLS_SVC_ID=$(curl -s "$WAVS_URL/services" | python3 -c "
import json, sys
d = json.load(sys.stdin)
sm_lower = '$TOOLS_SM'.lower()
for svc, sid in zip(d.get('services',[]), d.get('service_ids',[])):
    if svc.get('manager',{}).get('evm',{}).get('address','').lower() == sm_lower:
        print(sid); break
" 2>/dev/null) || true
  done
  [ -n "$TOOLS_SVC_ID" ] || die "Failed to get service_id for agent-tools"
fi
success "agent-tools service ID: $TOOLS_SVC_ID"

# =============================================================================
# 6. Register llm-agent service
# =============================================================================
info "Registering llm-agent with tool manifest..."

# Write agent config — tools reference TOOLS_SVC_ID with different workflow_ids
python3 - "$LLM_API_URL" "$LLM_MODEL" "$LLM_API_KEY" \
           "$TOOLS_SVC_ID" \
           "$WAVS_INTERNAL_URL" \
           "$TMPDIR_DEPLOY/agent-config.json" << 'PYEOF'
import json, sys
api_url, model, api_key, tools_svc_id, wavs_url, out_file = sys.argv[1:]
tools = [
    {
        "name": "weather",
        "service_id": tools_svc_id,
        "description": "Get current weather for a city. Args: {\"city\": string}",
        "workflow_id": "weather"
    },
    {
        "name": "crypto_price",
        "service_id": tools_svc_id,
        "description": "Get current cryptocurrency price in USD. Args: {\"symbol\": string} e.g. BTC, ETH, SOL",
        "workflow_id": "crypto_price"
    }
]
config = {
    "llm_api_url": api_url,
    "llm_model": model,
    "tools": json.dumps(tools),
    "max_tool_calls": "5",
    "wavs_node_url": wavs_url
}
if api_key:
    config["llm_api_key"] = api_key
with open(out_file, 'w') as f:
    json.dump(config, f, indent=2)
PYEOF

echo "  Agent config:"
python3 -m json.tool "$TMPDIR_DEPLOY/agent-config.json" | sed 's/^/    /'
echo ""

# Build agent service manifest
python3 - "$AGENT_SM" "$AGENT_TRIGGER" "$AGENT_DIGEST" "$AGENT_SUBMIT" \
           "$AGG_DIGEST" "$EVENT_HASH" "$CHAIN_ID" \
           "$TMPDIR_DEPLOY/agent-config.json" \
           "$TMPDIR_DEPLOY/agent-service.json" << 'PYEOF'
import json, sys
sm, trigger, comp_digest, submit, agg, event_hash, chain_id, config_file, out_file = sys.argv[1:]
with open(config_file) as f:
    config = json.load(f)
svc = {
    "name": "llm-agent",
    "status": "active",
    "manager": {"evm": {"chain": chain_id, "address": sm}},
    "workflows": {
        "default": {
            "trigger": {
                "evm_contract_event": {
                    "chain": chain_id,
                    "address": trigger,
                    "event_hash": event_hash
                }
            },
            "component": {
                "source": {"digest": comp_digest},
                "permissions": {
                    "allowed_http_hosts": "all",
                    "file_system": False,
                    "raw_sockets": False,
                    "dns_resolution": True
                },
                "env_keys": [],
                "config": config,
                "time_limit_seconds": 300
            },
            "submit": {
                "aggregator": {
                    "component": {
                        "source": {"digest": agg},
                        "permissions": {
                            "allowed_http_hosts": "none",
                            "file_system": False,
                            "raw_sockets": False,
                            "dns_resolution": False
                        },
                        "env_keys": [],
                        "config": {chain_id: submit}
                    },
                    "signature_kind": {"algorithm": "secp256k1", "prefix": "eip191"}
                }
            }
        }
    }
}
with open(out_file, 'w') as f:
    json.dump(svc, f)
PYEOF

AGENT_HASH_RESP=$(curl -s -X POST "$WAVS_URL/dev/services" \
  -H "Content-Type: application/json" \
  -d @"$TMPDIR_DEPLOY/agent-service.json")
AGENT_HASH=$(extract "$AGENT_HASH_RESP" "['hash']") || true
[ -n "$AGENT_HASH" ] || { echo "  Raw: $AGENT_HASH_RESP" >&2; die "Failed to save llm-agent service"; }

cast send "$AGENT_SM" "setServiceURI(string)" "http://127.0.0.1:8041/dev/services/$AGENT_HASH" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet >/dev/null 2>&1

AGENT_REG=$(curl -s -X POST "$WAVS_URL/services" \
  -H "Content-Type: application/json" \
  -d "{\"service_manager\":{\"evm\":{\"chain\":\"$CHAIN_ID\",\"address\":\"$AGENT_SM\"}}}")

AGENT_SVC_ID=$(echo "$AGENT_REG" | python3 -c "import json,sys; print(json.load(sys.stdin)['service_id'])" 2>/dev/null) || true

if [ -z "$AGENT_SVC_ID" ]; then
  attempts=0
  while [ -z "$AGENT_SVC_ID" ] && [ $attempts -lt 20 ]; do
    sleep 1; attempts=$((attempts + 1))
    AGENT_SVC_ID=$(curl -s "$WAVS_URL/services" | python3 -c "
import json, sys
d = json.load(sys.stdin)
sm_lower = '$AGENT_SM'.lower()
for svc, sid in zip(d.get('services',[]), d.get('service_ids',[])):
    if svc.get('manager',{}).get('evm',{}).get('address','').lower() == sm_lower:
        print(sid); break
" 2>/dev/null) || true
  done
  [ -n "$AGENT_SVC_ID" ] || die "Failed to get service_id for llm-agent"
fi
success "llm-agent service ID: $AGENT_SVC_ID"

# =============================================================================
# 7. Fund and register signing keys
#    - agent-tools: call signer for both workflows; register each unique key
#    - llm-agent:   one signing key
# =============================================================================
info "Funding and registering signing keys..."

get_signer_key() {
  local svc_id="$1" workflow_id="$2" sm="$3"
  local resp
  resp=$(curl -s -X POST "$WAVS_URL/services/signer" \
    -H "Content-Type: application/json" \
    -d "{\"service_id\":\"$svc_id\",\"workflow_id\":\"$workflow_id\",\"service_manager\":{\"evm\":{\"chain\":\"$CHAIN_ID\",\"address\":\"$sm\"}}}")
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['secp256k1']['evm_address'])" "$resp" 2>/dev/null || true
}

fund_key() {
  local key="$1" sm="$2"
  cast send "$key" --value 1ether --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
  cast send "$sm" "setOperatorWeight(address,uint256)" "$key" 100 \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
}

# Tools service — get keys for both workflows, register unique ones
TOOLS_KEY_WEATHER=$(get_signer_key "$TOOLS_SVC_ID" "weather"       "$TOOLS_SM")
TOOLS_KEY_CRYPTO=$(get_signer_key  "$TOOLS_SVC_ID" "crypto_price"  "$TOOLS_SM")
[ -n "$TOOLS_KEY_WEATHER" ] || die "Failed to get signing key for agent-tools/weather"
[ -n "$TOOLS_KEY_CRYPTO"  ] || die "Failed to get signing key for agent-tools/crypto_price"

fund_key "$TOOLS_KEY_WEATHER" "$TOOLS_SM"
success "agent-tools weather key:      $TOOLS_KEY_WEATHER"

if [ "$TOOLS_KEY_CRYPTO" != "$TOOLS_KEY_WEATHER" ]; then
  fund_key "$TOOLS_KEY_CRYPTO" "$TOOLS_SM"
  success "agent-tools crypto_price key: $TOOLS_KEY_CRYPTO"
else
  success "agent-tools crypto_price key: $TOOLS_KEY_CRYPTO (shared with weather)"
fi

# Agent service
AGENT_KEY=$(get_signer_key "$AGENT_SVC_ID" "default" "$AGENT_SM")
[ -n "$AGENT_KEY" ] || die "Failed to get signing key for llm-agent"
fund_key "$AGENT_KEY" "$AGENT_SM"
success "llm-agent key:                $AGENT_KEY"

# =============================================================================
# 8. Fire the agent trigger
# =============================================================================
echo ""
info "Firing agent trigger..."
echo "  Prompt: \"$PROMPT\""
echo ""

cast send "$AGENT_TRIGGER" "addTrigger(string)" "$PROMPT" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --quiet

success "Trigger sent!"
echo ""
echo "Waiting for agent response (LLM inference + tool calls + aggregation)..."
echo "Typical: 30–60s for OpenAI/Anthropic, 2–5min for local Ollama"
echo ""

WAIT="${WAIT_SECONDS:-180}"
for i in $(seq 1 $WAIT); do
  IS_COMPLETE=$(cast call "$AGENT_SUBMIT" "isComplete(uint64)(bool)" "1" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "false")
  if [ "$IS_COMPLETE" = "true" ]; then
    echo ""
    success "Agent response committed! (after ${i}s)"
    break
  fi

  if [ $i -le 15 ]; then
    stage="initializing service..."
  elif [ $i -le 90 ]; then
    stage="LLM inference + tool calls running..."
  else
    stage="waiting for aggregation..."
  fi
  printf "\r  [%3ds / %ds] %s" "$i" "$WAIT" "$stage"
  sleep 1
done

echo ""

# =============================================================================
# 9. Read and display result
# =============================================================================
IS_COMPLETE=$(cast call "$AGENT_SUBMIT" "isComplete(uint64)(bool)" "1" \
  --rpc-url "$RPC_URL" 2>/dev/null || echo "false")

echo ""
if [ "$IS_COMPLETE" = "true" ]; then
  RESPONSE=$(cast call "$AGENT_SUBMIT" "getResponse(uint64)(string,bytes32)" "1" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "(decode error)")

  echo "╔══════════════════════════════════════════════════════════════╗"
  success "AGENT RESPONSE:"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  $RESPONSE"
  echo ""

  echo "  On-chain tool call audit trail:"
  TOOL_CALLS=$(cast call "$AGENT_SUBMIT" \
    "getToolCalls(uint64)((string,bytes32,bytes32)[])" "1" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "(decode error)")
  echo "  $TOOL_CALLS"
  echo ""
  echo "  Verify manually:"
  echo "    cast call $AGENT_SUBMIT 'getToolCalls(uint64)((string,bytes32,bytes32)[])' 1 --rpc-url $RPC_URL"
  echo ""
else
  warn "Not committed yet — check logs for what happened"
  echo ""
  echo "  cast call $AGENT_SUBMIT 'isComplete(uint64)(bool)' 1 --rpc-url $RPC_URL"
  echo "  cast call $AGENT_SUBMIT 'getResponse(uint64)(string,bytes32)' 1 --rpc-url $RPC_URL"
  echo ""
fi

# =============================================================================
# Summary table
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                   Deployment Summary                            ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
printf "║  %-16s  service_id = %-32s  ║\n" "agent-tools"    "${TOOLS_SVC_ID:0:32}"
printf "║  %-16s  sm         = %-32s  ║\n" ""               "$TOOLS_SM"
printf "║  %-16s  weather    = %-32s  ║\n" ""               "$WEATHER_TRIGGER"
printf "║  %-16s  crypto     = %-32s  ║\n" ""               "$CRYPTO_TRIGGER"
echo   "║                                                                  ║"
printf "║  %-16s  service_id = %-32s  ║\n" "llm-agent"      "${AGENT_SVC_ID:0:32}"
printf "║  %-16s  trigger    = %-32s  ║\n" ""               "$AGENT_TRIGGER"
printf "║  %-16s  submit     = %-32s  ║\n" ""               "$AGENT_SUBMIT"
echo   "║                                                                  ║"
printf "║  LLM: %-58s  ║\n" "$LLM_API_URL ($LLM_MODEL)"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "Execution logs:"
echo "  curl -s $WAVS_URL/dev/logs/$AGENT_SVC_ID  | python3 -m json.tool | grep -A3 message"
echo "  curl -s $WAVS_URL/dev/logs/$TOOLS_SVC_ID  | python3 -m json.tool | grep -A3 message"
echo ""
