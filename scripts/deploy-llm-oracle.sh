#!/usr/bin/env bash
# =============================================================================
# deploy-llm-oracle.sh — Full end-to-end deploy for llm-oracle on local Anvil + WAVS
#
# Requires:
#   - Anvil running at $RPC_URL (default: http://localhost:8545)
#   - WAVS node running at $WAVS_URL (default: http://host.docker.internal:8041)
#     with dev_endpoints_enabled = true
#   - Aggregator running at $AGGREGATOR_URL (default: http://host.docker.internal:8040)
#   - forge, cast, cargo-component in PATH
#   - An LLM accessible (Ollama default: http://host.docker.internal:11434)
#
# Config (optional env vars):
#   LLM_API_URL   — LLM API base URL (default: http://host.docker.internal:11434)
#   LLM_MODEL     — Model name (default: llama3.2)
#   LLM_API_KEY   — API key; if set, switches to OpenAI-compatible mode
#
# Usage:
#   ./scripts/deploy-llm-oracle.sh
#   LLM_API_URL=https://api.openai.com LLM_MODEL=gpt-4o LLM_API_KEY=sk-... ./scripts/deploy-llm-oracle.sh
# =============================================================================
set -euo pipefail

RPC_URL="${RPC_URL:-http://localhost:8545}"
WAVS_URL="${WAVS_URL:-http://host.docker.internal:8041}"
AGGREGATOR_URL="${AGGREGATOR_URL:-http://host.docker.internal:8040}"
CHAIN_ID="${CHAIN_ID:-evm:31337}"
PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
AGGREGATOR_CRED="${AGGREGATOR_CRED:-0xc63aff4f9B0ebD48B6C9814619cAbfD9a7710A58}"

LLM_API_URL="${LLM_API_URL:-http://host.docker.internal:11434}"
LLM_MODEL="${LLM_MODEL:-llama3.2}"
LLM_API_KEY="${LLM_API_KEY:-}"

GREEN="\033[0;32m"; BLUE="\033[0;34m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; NC="\033[0m"
info()    { echo -e "${BLUE}▶ $*${NC}"; }
success() { echo -e "${GREEN}✅ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
die()     { echo -e "${RED}❌ $*${NC}"; exit 1; }

# =============================================================================
# 1. Build WASM component
# =============================================================================
info "Building llm-oracle WASM component..."
cargo component build --release -p llm-oracle \
  --target wasm32-wasip1 2>&1 | grep -E "Compiling|Finished|Creating|error"
success "Component built"

LLM_WASM="target/wasm32-wasip1/release/llm_oracle.wasm"
[ -f "$LLM_WASM" ] || die "llm_oracle.wasm not found at $LLM_WASM"

# =============================================================================
# 2. Deploy contracts
# =============================================================================
info "Deploying contracts via forge..."

# Deploy SimpleTrigger (reuse existing WavsTrigger interface)
# and LLMSubmit (new contract for storing LLM responses)
DEPLOY_OUT=$(forge script script/DeployLLMOracle.s.sol \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --private-key "$PRIVATE_KEY" \
  2>&1)

echo "$DEPLOY_OUT" | tail -30

TRIGGER_ADDR=$(echo "$DEPLOY_OUT"    | grep "TRIGGER_ADDR="         | tail -1 | cut -d= -f2 | tr -d ' ')
SM_ADDR=$(echo "$DEPLOY_OUT"         | grep "SERVICE_MANAGER_ADDR=" | tail -1 | cut -d= -f2 | tr -d ' ')
SUBMIT_ADDR=$(echo "$DEPLOY_OUT"     | grep "LLM_SUBMIT_ADDR="      | tail -1 | cut -d= -f2 | tr -d ' ')

[ -n "$TRIGGER_ADDR" ] || die "Failed to parse TRIGGER_ADDR from forge output:\n$DEPLOY_OUT"
[ -n "$SM_ADDR" ]      || die "Failed to parse SERVICE_MANAGER_ADDR from forge output"
[ -n "$SUBMIT_ADDR" ]  || die "Failed to parse LLM_SUBMIT_ADDR from forge output"

success "Contracts deployed"
echo "  SimpleTrigger:        $TRIGGER_ADDR"
echo "  SimpleServiceManager: $SM_ADDR"
echo "  LLMSubmit:            $SUBMIT_ADDR"

# =============================================================================
# 3. Get NewTrigger event hash
# =============================================================================
info "Computing NewTrigger event hash..."
EVENT_SIG="NewTrigger(bytes)"
EVENT_HASH=$(cast keccak "$EVENT_SIG")
success "NewTrigger event hash: $EVENT_HASH"

# =============================================================================
# 4. Upload WASM component
# =============================================================================
info "Uploading llm-oracle component..."
LLM_DIGEST=$(curl -sf -X POST "$WAVS_URL/dev/components" \
  -H "Content-Type: application/wasm" \
  --data-binary @"$LLM_WASM" | python3 -c "import json,sys; print(json.load(sys.stdin)['digest'])")
success "LLM Oracle digest: $LLM_DIGEST"

info "Uploading aggregator component..."
AGG_WASM="target/wasm32-wasip1/release/aggregator.wasm"
if [ ! -f "$AGG_WASM" ]; then
  info "Building aggregator..."
  cargo component build --release -p aggregator --target wasm32-wasip1 2>&1 | grep -E "Compiling|Finished|Creating|error"
fi
AGG_DIGEST=$(curl -sf -X POST "$WAVS_URL/dev/components" \
  -H "Content-Type: application/wasm" \
  --data-binary @"$AGG_WASM" | python3 -c "import json,sys; print(json.load(sys.stdin)['digest'])")
success "Aggregator digest: $AGG_DIGEST"

# =============================================================================
# 5. Build service definition with LLM config vars
# =============================================================================
info "Saving service definition..."

# Build config section (with optional API key)
if [ -n "$LLM_API_KEY" ]; then
  CONFIG_JSON="{\"llm_api_url\": \"$LLM_API_URL\", \"llm_model\": \"$LLM_MODEL\", \"llm_api_key\": \"$LLM_API_KEY\"}"
else
  CONFIG_JSON="{\"llm_api_url\": \"$LLM_API_URL\", \"llm_model\": \"$LLM_MODEL\"}"
fi

SERVICE_JSON=$(python3 -c "
import json
config = json.loads('$CONFIG_JSON')
print(json.dumps({
  'name': 'llm-oracle',
  'status': 'active',
  'manager': {'evm': {'chain': '$CHAIN_ID', 'address': '$SM_ADDR'}},
  'workflows': {
    'default': {
      'trigger': {
        'evm_contract_event': {
          'chain': '$CHAIN_ID',
          'address': '$TRIGGER_ADDR',
          'event_hash': '$EVENT_HASH'
        }
      },
      'component': {
        'source': {'digest': '$LLM_DIGEST'},
        'permissions': {
          'allowed_http_hosts': 'all',
          'file_system': False,
          'raw_sockets': False,
          'dns_resolution': True
        },
        'env_keys': [],
        'config': config,
        'time_limit_seconds': 120
      },
      'submit': {
        'aggregator': {
          'component': {
            'source': {'digest': '$AGG_DIGEST'},
            'permissions': {
              'allowed_http_hosts': 'none',
              'file_system': False,
              'raw_sockets': False,
              'dns_resolution': False
            },
            'env_keys': [],
            'config': {'$CHAIN_ID': '$SUBMIT_ADDR'}
          },
          'signature_kind': {'algorithm': 'secp256k1', 'prefix': 'eip191'}
        }
      }
    }
  }
}))
")

SERVICE_HASH=$(echo "$SERVICE_JSON" | curl -sf -X POST "$WAVS_URL/dev/services" \
  -H "Content-Type: application/json" \
  -d @- | python3 -c "import json,sys; print(json.load(sys.stdin)['hash'])")
success "Service saved, hash: $SERVICE_HASH"

# =============================================================================
# 6. Set service URI on-chain
# =============================================================================
info "Setting service URI on-chain..."
SERVICE_URI="http://127.0.0.1:8041/dev/services/$SERVICE_HASH"

cast send "$SM_ADDR" "setServiceURI(string)" "$SERVICE_URI" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --quiet
success "ServiceURI set: $SERVICE_URI"

# =============================================================================
# 7. Register service with WAVS node
# =============================================================================
info "Registering service with WAVS node..."
curl -sf -X POST "$WAVS_URL/services" \
  -H "Content-Type: application/json" \
  -d "{\"service_manager\":{\"evm\":{\"chain\":\"$CHAIN_ID\",\"address\":\"$SM_ADDR\"}}}" \
  > /dev/null
success "Service registered"

sleep 2  # Let node assign HD index

# =============================================================================
# 8. Get service ID and signing key
# =============================================================================
info "Fetching service ID and signing key..."

SERVICES_RESP=$(curl -sf "$WAVS_URL/services")
SERVICE_ID=$(echo "$SERVICES_RESP" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ids=d.get('service_ids',[])
if not ids: raise SystemExit('No services registered')
print(ids[-1])
")
success "Service ID: $SERVICE_ID"

SIGNER_RESP=$(curl -sf -X POST "$WAVS_URL/services/signer" \
  -H "Content-Type: application/json" \
  -d "{\"service_id\":\"$SERVICE_ID\",\"workflow_id\":\"default\",\"service_manager\":{\"evm\":{\"chain\":\"$CHAIN_ID\",\"address\":\"$SM_ADDR\"}}}")

HD_INDEX=$(echo "$SIGNER_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['secp256k1']['hd_index'])")
SIGNING_KEY=$(echo "$SIGNER_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['secp256k1']['evm_address'])")
success "Signing key: $SIGNING_KEY (HD index $HD_INDEX)"

# =============================================================================
# 9. Fund signing key
# =============================================================================
info "Funding signing key..."
cast send "$SIGNING_KEY" \
  --value 1ether \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --quiet
success "Funded $SIGNING_KEY with 1 ETH"

# =============================================================================
# 10. Register operator (set weight on SimpleServiceManager)
# =============================================================================
info "Setting operator weight..."
cast send "$SM_ADDR" "setOperatorWeight(address,uint256)" "$SIGNING_KEY" 100 \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --quiet
success "setOperatorWeight($SIGNING_KEY, 100)"

# =============================================================================
# 11. Fire a test trigger
# =============================================================================
info "Firing test trigger: 'What is 2+2? Answer in one word.'"
cast send "$TRIGGER_ADDR" "addTrigger(string)" "What is 2+2? Answer in one word." \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --quiet
success "Trigger sent"

echo "Waiting 60 seconds for LLM inference + WAVS processing..."
sleep 60

# =============================================================================
# 12. Verify: poll getResponse(1)
# =============================================================================
info "Checking LLM result for trigger ID 1..."

TRIGGER_ID_ENUM=$(cast call "$TRIGGER_ADDR" "nextTriggerId()(uint64)" --rpc-url "$RPC_URL")

RESPONSE=$(cast call "$SUBMIT_ADDR" "getResponse(uint64)(string,bytes32)" "1" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
IS_COMPLETE=$(cast call "$SUBMIT_ADDR" "isComplete(uint64)(bool)" "1" --rpc-url "$RPC_URL" 2>/dev/null || echo "false")

if [ "$IS_COMPLETE" = "true" ]; then
  success "LLM response received! 🎉"
  echo "  Response: $RESPONSE"
  echo ""
  echo "════════════════════════════════════════"
  success "LLM ORACLE END-TO-END COMPLETE!"
  echo "  Trigger:         $TRIGGER_ADDR"
  echo "  ServiceManager:  $SM_ADDR"
  echo "  LLMSubmit:       $SUBMIT_ADDR"
  echo "  Service ID:      $SERVICE_ID"
  echo "  Signing key:     $SIGNING_KEY (HD $HD_INDEX)"
  echo "  LLM API:         $LLM_API_URL"
  echo "  Model:           $LLM_MODEL"
  echo "════════════════════════════════════════"
else
  warn "Response not yet committed — WAVS/LLM may still be processing"
  warn "Poll manually:"
  warn "  cast call $SUBMIT_ADDR 'isComplete(uint64)(bool)' 1 --rpc-url $RPC_URL"
  warn "  cast call $SUBMIT_ADDR 'getResponse(uint64)(string,bytes32)' 1 --rpc-url $RPC_URL"
  echo ""
  echo "Contract addresses:"
  echo "  TRIGGER_ADDR=$TRIGGER_ADDR"
  echo "  SERVICE_MANAGER_ADDR=$SM_ADDR"
  echo "  LLM_SUBMIT_ADDR=$SUBMIT_ADDR"
  echo "  SERVICE_ID=$SERVICE_ID"
  echo "  SIGNING_KEY=$SIGNING_KEY"
fi
