#!/usr/bin/env bash
# =============================================================================
# deploy-llm-agent.sh — Deploy and test the verifiable agent tool protocol
#
# Deploys three services:
#   1. weather-oracle  — tool: get current weather for a city
#   2. crypto-price    — tool: get current crypto price (CoinGecko)
#   3. llm-agent       — orchestrator: ReAct loop calling the above tools
#
# Requires:
#   - Anvil running at $RPC_URL           (default: http://localhost:8545)
#   - WAVS node at $WAVS_URL              (default: http://localhost:8041)
#   - LLM accessible via $LLM_API_URL    (default: http://localhost:11434 Ollama)
#   - forge, cast, cargo-component in PATH
#
# Config:
#   LLM_API_URL   — default: http://localhost:11434
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

# LLM config — component uses host.docker.internal since it runs inside Docker
LLM_API_URL="${LLM_API_URL:-http://host.docker.internal:11434}"
LLM_MODEL="${LLM_MODEL:-llama3.2}"
LLM_API_KEY="${LLM_API_KEY:-}"
PROMPT="${PROMPT:-What is the current weather in London and the current price of BTC? Answer in two sentences.}"

# WAVS URL that the WASM component uses to call other services.
# Component runs inside the WAVS Docker container, so localhost reaches the WAVS REST API directly.
# (host.docker.internal is Mac/Windows Docker Desktop only — not available on Linux)
WAVS_INTERNAL_URL="${WAVS_INTERNAL_URL:-http://localhost:8041}"

GREEN="\033[0;32m"; BLUE="\033[0;34m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; NC="\033[0m"
info()    { echo -e "${BLUE}▶ $*${NC}"; }
success() { echo -e "${GREEN}✅ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
die()     { echo -e "${RED}❌ $*${NC}"; exit 1; }

# Extract a field from JSON response — shows raw response on failure
json_field() {
  local field="$1"
  local raw
  raw=$(cat)
  python3 -c "
import json, sys
try:
    d = json.loads('''$( echo "$raw" | python3 -c "import sys; print(sys.stdin.read().replace(\"'\", \"'\\\\''\"))" )''')
    val = d$(echo "$field")
    print(val)
except Exception as e:
    print('ERROR: ' + str(e), file=sys.stderr)
    print('Raw response: ' + '''$( echo "$raw" | head -c 500 )''', file=sys.stderr)
    sys.exit(1)
" 2>&1 || { echo "JSON parse failed for field $field"; echo "Raw: $raw" >&2; exit 1; }
}

# Simpler extractor using python -c with heredoc-safe approach
extract() {
  local resp="$1"
  local field="$2"
  python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d$field)
except Exception as e:
    print('', end='')
    sys.exit(1)
" "$resp"
}

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          Verifiable Agent Tool Protocol — Deploy             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  WAVS:   $WAVS_URL"
echo "  LLM:    $LLM_API_URL  (model: $LLM_MODEL)"
echo "  Prompt: $PROMPT"
echo ""

# =============================================================================
# 1. Build all WASM components
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
# 2. Deploy contracts — 3 independent sets (agent + weather tool + crypto tool)
# =============================================================================
info "Deploying contracts (3 sets: agent, weather tool, crypto tool)..."

deploy_contracts() {
  local out
  out=$(forge script script/DeployLLMOracle.s.sol \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --private-key "$PRIVATE_KEY" \
    2>&1)
  local trigger sm submit
  trigger=$(echo "$out" | grep "TRIGGER_ADDR="         | tail -1 | cut -d= -f2 | tr -d ' \r')
  sm=$(echo "$out"      | grep "SERVICE_MANAGER_ADDR=" | tail -1 | cut -d= -f2 | tr -d ' \r')
  submit=$(echo "$out"  | grep "LLM_SUBMIT_ADDR="      | tail -1 | cut -d= -f2 | tr -d ' \r')
  [ -n "$trigger" ] || { echo "$out" >&2; die "No TRIGGER_ADDR in forge output"; }
  [ -n "$sm" ]      || die "No SERVICE_MANAGER_ADDR in forge output"
  [ -n "$submit" ]  || die "No LLM_SUBMIT_ADDR in forge output"
  echo "$trigger $sm $submit"
}

read -r AGENT_TRIGGER  AGENT_SM  AGENT_SUBMIT  <<< "$(deploy_contracts)"
read -r WEATHER_TRIGGER WEATHER_SM WEATHER_SUBMIT <<< "$(deploy_contracts)"
read -r CRYPTO_TRIGGER  CRYPTO_SM  CRYPTO_SUBMIT  <<< "$(deploy_contracts)"

success "Contracts deployed"
echo "  Agent:   trigger=$AGENT_TRIGGER  sm=$AGENT_SM"
echo "  Weather: trigger=$WEATHER_TRIGGER"
echo "  Crypto:  trigger=$CRYPTO_TRIGGER"

EVENT_HASH=$(cast keccak "NewTrigger(bytes)")

# =============================================================================
# 3. Upload WASM components to WAVS node
# =============================================================================
info "Uploading components to WAVS node at $WAVS_URL..."

upload_component() {
  local name="$1" wasm_path="$2"
  local resp
  resp=$(curl -s -X POST "$WAVS_URL/dev/components" \
    -H "Content-Type: application/wasm" \
    --data-binary @"$wasm_path")
  local digest
  digest=$(extract "$resp" "['digest']") || { echo ""; }
  if [ -z "$digest" ]; then
    echo "  Raw response: $resp" >&2
    die "Failed to upload $name — empty digest. Is WAVS running at $WAVS_URL?"
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
# 4. Register a service — write JSON to tmpfile to avoid interpolation issues
# =============================================================================
TMPDIR_DEPLOY=$(mktemp -d)
trap "rm -rf $TMPDIR_DEPLOY" EXIT

register_service() {
  local name="$1" sm="$2" trigger="$3" component_digest="$4" submit="$5"
  local config_file="$6"  # path to a JSON file with component config vars

  local svc_file="$TMPDIR_DEPLOY/${name}-service.json"

  python3 - "$name" "$sm" "$trigger" "$EVENT_HASH" "$component_digest" \
                    "$AGG_DIGEST" "$submit" "$CHAIN_ID" "$config_file" "$svc_file" << 'PYEOF'
import json, sys
name, sm, trigger, event_hash, comp_digest, agg_digest, submit, chain_id, config_file, out_file = sys.argv[1:]
with open(config_file) as f:
    config = json.load(f)
svc = {
    "name": name,
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
                        "source": {"digest": agg_digest},
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

  # POST service definition
  local resp
  resp=$(curl -s -X POST "$WAVS_URL/dev/services" \
    -H "Content-Type: application/json" \
    -d @"$svc_file")
  local hash
  hash=$(extract "$resp" "['hash']") || true
  if [ -z "$hash" ]; then
    echo "  Raw response: $resp" >&2
    die "Failed to save service $name"
  fi

  # Set URI on-chain
  local uri="http://127.0.0.1:8041/dev/services/$hash"
  cast send "$sm" "setServiceURI(string)" "$uri" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet \
    >/dev/null 2>&1

  # Register with WAVS node
  curl -s -X POST "$WAVS_URL/services" \
    -H "Content-Type: application/json" \
    -d "{\"service_manager\":{\"evm\":{\"chain\":\"$CHAIN_ID\",\"address\":\"$sm\"}}}" \
    > /dev/null

  # Poll until this specific service_manager address appears — avoids stale IDs from prior deploys
  local svc_id=""
  local attempts=0
  while [ -z "$svc_id" ] && [ $attempts -lt 20 ]; do
    sleep 1
    attempts=$((attempts + 1))
    svc_id=$(curl -s "$WAVS_URL/services" | python3 -c "
import json, sys
d = json.load(sys.stdin)
services = d.get('services', [])
service_ids = d.get('service_ids', [])
sm_lower = '$sm'.lower()
for i, svc in enumerate(services):
    mgr = svc.get('manager', {}).get('evm', {}).get('address', '').lower()
    if mgr == sm_lower and i < len(service_ids):
        print(service_ids[i])
        break
" 2>/dev/null) || true
  done

  if [ -z "$svc_id" ]; then
    echo "  Timed out waiting for service '$name' after ${attempts}s" >&2
    curl -s "$WAVS_URL/services" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('Services:', [s.get('name') for s in d.get('services',[])])
print('IDs:', d.get('service_ids',[]))
" >&2
    die "Failed to get service_id for $name"
  fi

  info "  $name registered with ID: $svc_id (after ${attempts}s)" >&2
  echo "$svc_id"
}

# =============================================================================
# 5. Register weather-oracle
# =============================================================================
info "Registering weather-oracle..."
echo '{}' > "$TMPDIR_DEPLOY/weather-config.json"
WEATHER_SVC_ID=$(register_service \
  weather-oracle "$WEATHER_SM" "$WEATHER_TRIGGER" \
  "$WEATHER_DIGEST" "$WEATHER_SUBMIT" "$TMPDIR_DEPLOY/weather-config.json" \
  | grep -E '^[0-9a-f]{64}$' | tail -1)
success "weather-oracle service ID: $WEATHER_SVC_ID"

# =============================================================================
# 6. Register crypto-price
# =============================================================================
info "Registering crypto-price..."
echo '{}' > "$TMPDIR_DEPLOY/crypto-config.json"
CRYPTO_SVC_ID=$(register_service \
  crypto-price "$CRYPTO_SM" "$CRYPTO_TRIGGER" \
  "$CRYPTO_DIGEST" "$CRYPTO_SUBMIT" "$TMPDIR_DEPLOY/crypto-config.json" \
  | grep -E '^[0-9a-f]{64}$' | tail -1)
success "crypto-price service ID: $CRYPTO_SVC_ID"

# =============================================================================
# 7. Register llm-agent (config includes tool manifest with real service IDs)
# =============================================================================
info "Registering llm-agent with tool manifest..."

# Write agent config to file — Python handles all escaping cleanly
python3 - "$LLM_API_URL" "$LLM_MODEL" "$LLM_API_KEY" \
           "$WEATHER_SVC_ID" "$CRYPTO_SVC_ID" \
           "$WAVS_INTERNAL_URL" \
           "$TMPDIR_DEPLOY/agent-config.json" << 'PYEOF'
import json, sys
api_url, model, api_key, weather_id, crypto_id, wavs_url, out_file = sys.argv[1:]
tools = [
    {
        "name": "weather",
        "service_id": weather_id,
        "description": "Get current weather for a city. Args: {\"city\": string}",
        "workflow_id": "default"
    },
    {
        "name": "crypto_price",
        "service_id": crypto_id,
        "description": "Get current cryptocurrency price in USD. Args: {\"symbol\": string} e.g. BTC, ETH, SOL",
        "workflow_id": "default"
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
cat "$TMPDIR_DEPLOY/agent-config.json" | python3 -m json.tool | sed 's/^/    /'
echo ""

AGENT_SVC_ID=$(register_service \
  llm-agent "$AGENT_SM" "$AGENT_TRIGGER" \
  "$AGENT_DIGEST" "$AGENT_SUBMIT" "$TMPDIR_DEPLOY/agent-config.json" \
  | grep -E '^[0-9a-f]{64}$' | tail -1)
success "llm-agent service ID: $AGENT_SVC_ID"

# =============================================================================
# 8. Fund and register signing keys for all three services
# =============================================================================
info "Funding and registering signing keys..."

fund_and_register() {
  local sm="$1" svc_id="$2" name="$3"
  local resp
  resp=$(curl -s -X POST "$WAVS_URL/services/signer" \
    -H "Content-Type: application/json" \
    -d "{\"service_id\":\"$svc_id\",\"workflow_id\":\"default\",\"service_manager\":{\"evm\":{\"chain\":\"$CHAIN_ID\",\"address\":\"$sm\"}}}")
  local key hd
  key=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['secp256k1']['evm_address'])" "$resp" 2>/dev/null) || true
  hd=$(python3  -c "import json,sys; d=json.loads(sys.argv[1]); print(d['secp256k1']['hd_index'])"   "$resp" 2>/dev/null) || true
  if [ -z "$key" ]; then
    echo "  Signer response: $resp" >&2
    die "Failed to get signing key for $name"
  fi
  cast send "$key" --value 1ether --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
  cast send "$sm" "setOperatorWeight(address,uint256)" "$key" 100 \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
  echo "$key (HD $hd)"
}

WEATHER_KEY=$(fund_and_register "$WEATHER_SM" "$WEATHER_SVC_ID" weather-oracle)
success "weather-oracle key: $WEATHER_KEY"

CRYPTO_KEY=$(fund_and_register "$CRYPTO_SM" "$CRYPTO_SVC_ID" crypto-price)
success "crypto-price key:   $CRYPTO_KEY"

AGENT_KEY=$(fund_and_register "$AGENT_SM" "$AGENT_SVC_ID" llm-agent)
success "llm-agent key:      $AGENT_KEY"

# =============================================================================
# 9. Fire the agent trigger
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
echo "Waiting for agent (LLM inference + tool calls + aggregation)..."
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
  printf "\r  [%3ds / %ds] polling isComplete(1)..." "$i" "$WAIT"
  sleep 1
done

echo ""

# =============================================================================
# 10. Read and display result
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
else
  warn "Not committed yet — check logs for what happened"
  echo ""
  echo "Poll manually:"
  echo "  cast call $AGENT_SUBMIT 'isComplete(uint64)(bool)' 1 --rpc-url $RPC_URL"
  echo "  cast call $AGENT_SUBMIT 'getResponse(uint64)(string,bytes32)' 1 --rpc-url $RPC_URL"
  echo ""
fi

echo "Check execution logs:"
echo "  curl -s $WAVS_URL/dev/logs/$AGENT_SVC_ID   | python3 -m json.tool | grep -A3 message"
echo "  curl -s $WAVS_URL/dev/logs/$WEATHER_SVC_ID | python3 -m json.tool | grep -A3 message"
echo "  curl -s $WAVS_URL/dev/logs/$CRYPTO_SVC_ID  | python3 -m json.tool | grep -A3 message"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  weather-oracle  svc=$WEATHER_SVC_ID"
echo "  crypto-price    svc=$CRYPTO_SVC_ID"
echo "  llm-agent       svc=$AGENT_SVC_ID"
echo "  LLMSubmit:      $AGENT_SUBMIT"
echo "  Agent trigger:  $AGENT_TRIGGER"
echo "════════════════════════════════════════════════════════════════"
