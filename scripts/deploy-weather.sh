#!/usr/bin/env bash
# =============================================================================
# deploy-weather.sh — Full end-to-end deploy for weather-oracle on local Anvil + WAVS
#
# Requires:
#   - Anvil running at $RPC_URL (default: http://localhost:8545)
#   - WAVS node running at $WAVS_URL (default: http://localhost:8041)
#     with dev_endpoints_enabled = true
#   - forge, cast, cargo-component in PATH
#
# Usage:
#   ./scripts/deploy-weather.sh
#   WAVS_URL=http://localhost:8041 RPC_URL=http://localhost:8545 ./scripts/deploy-weather.sh
# =============================================================================
set -euo pipefail

RPC_URL="${RPC_URL:-http://localhost:8545}"
WAVS_URL="${WAVS_URL:-http://localhost:8041}"
CHAIN_ID="${CHAIN_ID:-evm:31337}"
PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

GREEN="\033[0;32m"; BLUE="\033[0;34m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; NC="\033[0m"
info()    { echo -e "${BLUE}▶ $*${NC}"; }
success() { echo -e "${GREEN}✅ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
die()     { echo -e "${RED}❌ $*${NC}"; exit 1; }

# =============================================================================
# 1. Build WASM components
# =============================================================================
info "Building WASM components..."
cargo component build --release -p weather-oracle -p aggregator \
  --target wasm32-wasip1 2>&1 | grep -E "Compiling|Finished|Creating|error"
success "Components built"

WEATHER_WASM="target/wasm32-wasip1/release/weather_oracle.wasm"
AGG_WASM="target/wasm32-wasip1/release/aggregator.wasm"
[ -f "$WEATHER_WASM" ] || die "weather_oracle.wasm not found at $WEATHER_WASM"
[ -f "$AGG_WASM" ]     || die "aggregator.wasm not found at $AGG_WASM"

# =============================================================================
# 2. Deploy contracts
# =============================================================================
info "Deploying contracts via forge..."

DEPLOY_OUT=$(forge script script/Deploy.s.sol \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --private-key "$PRIVATE_KEY" \
  2>&1)

TRIGGER_ADDR=$(echo "$DEPLOY_OUT"    | grep "TRIGGER_ADDR="         | tail -1 | cut -d= -f2 | tr -d ' ')
SM_ADDR=$(echo "$DEPLOY_OUT"         | grep "SERVICE_MANAGER_ADDR=" | tail -1 | cut -d= -f2 | tr -d ' ')
SUBMIT_ADDR=$(echo "$DEPLOY_OUT"     | grep "SUBMIT_ADDR="          | tail -1 | cut -d= -f2 | tr -d ' ')

[ -n "$TRIGGER_ADDR" ] || die "Failed to parse TRIGGER_ADDR from forge output:\n$DEPLOY_OUT"
[ -n "$SM_ADDR" ]      || die "Failed to parse SERVICE_MANAGER_ADDR from forge output"
[ -n "$SUBMIT_ADDR" ]  || die "Failed to parse SUBMIT_ADDR from forge output"

success "Contracts deployed"
echo "  SimpleTrigger:        $TRIGGER_ADDR"
echo "  SimpleServiceManager: $SM_ADDR"
echo "  SimpleSubmit:         $SUBMIT_ADDR"

# =============================================================================
# 3. Get NewTrigger event hash
# =============================================================================
info "Computing NewTrigger event hash..."
EVENT_HASH=$(cast keccak "NewTrigger(bytes)")
success "NewTrigger event hash: $EVENT_HASH"

# =============================================================================
# 4. Upload WASM components
# =============================================================================
info "Uploading weather-oracle component..."
WEATHER_DIGEST=$(curl -sf -X POST "$WAVS_URL/dev/components" \
  -H "Content-Type: application/wasm" \
  --data-binary @"$WEATHER_WASM" | python3 -c "import json,sys; print(json.load(sys.stdin)['digest'])")
success "Weather-oracle digest: $WEATHER_DIGEST"

info "Uploading aggregator component..."
AGG_DIGEST=$(curl -sf -X POST "$WAVS_URL/dev/components" \
  -H "Content-Type: application/wasm" \
  --data-binary @"$AGG_WASM" | python3 -c "import json,sys; print(json.load(sys.stdin)['digest'])")
success "Aggregator digest: $AGG_DIGEST"

# =============================================================================
# 5. Build and save service definition
# =============================================================================
info "Saving service definition..."

SERVICE_JSON=$(python3 -c "
import json
print(json.dumps({
  'name': 'weather-oracle',
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
        'source': {'digest': '$WEATHER_DIGEST'},
        'permissions': {
          'allowed_http_hosts': 'all',
          'file_system': False,
          'raw_sockets': False,
          'dns_resolution': True
        },
        'env_keys': [],
        'config': {}
      },
      'submit': {
        'aggregator': {
          'component': {
            'source': {'digest': '$AGG_DIGEST'},
            'permissions': {
              'allowed_http_hosts': 'all',
              'file_system': False,
              'raw_sockets': False,
              'dns_resolution': True
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
REG_RESP=$(curl -sf -X POST "$WAVS_URL/services" \
  -H "Content-Type: application/json" \
  -d "{\"service_manager\":{\"evm\":{\"chain\":\"$CHAIN_ID\",\"address\":\"$SM_ADDR\"}}}")
success "Service registered"

# =============================================================================
# 8. Get service ID and signing key
# =============================================================================
info "Fetching service ID and signing key..."

# WAVS v1.1+ returns service_id directly from POST /services
SERVICE_ID=$(echo "$REG_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['service_id'])" 2>/dev/null) || true
if [ -z "$SERVICE_ID" ]; then
  sleep 2  # fallback: poll for older WAVS
  SERVICE_ID=$(curl -sf "$WAVS_URL/services" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ids=d.get('service_ids',[])
if not ids: raise SystemExit('No services registered')
print(ids[-1])
")
fi
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
# 10. Register operator weight
# =============================================================================
info "Setting operator weight..."
cast send "$SM_ADDR" "setOperatorWeight(address,uint256)" "$SIGNING_KEY" 100 \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --quiet
success "setOperatorWeight($SIGNING_KEY, 100)"

# =============================================================================
# 11. Smoke test — fetch weather for London
# =============================================================================
TEST_LOCATION="${1:-London}"
info "Firing test trigger for: $TEST_LOCATION"
cast send "$TRIGGER_ADDR" "addTrigger(string)" "$TEST_LOCATION" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --quiet

echo "Waiting 20 seconds for WAVS to process..."
sleep 20

info "Checking result..."
TRIGGER_ID=$(cast call "$TRIGGER_ADDR" "nextTriggerId()(uint64)" --rpc-url "$RPC_URL")
IS_VALID=$(cast call "$SUBMIT_ADDR" "isValidTriggerId(uint64)(bool)" "$TRIGGER_ID" --rpc-url "$RPC_URL")

if [ "$IS_VALID" = "true" ]; then
  success "isValidTriggerId($TRIGGER_ID) = true 🎉"

  # Decode and pretty-print the weather result
  RESULT_HEX=$(cast call "$SUBMIT_ADDR" "getData(uint64)(bytes)" "$TRIGGER_ID" --rpc-url "$RPC_URL")
  echo ""
  echo "Weather result:"
  echo "$RESULT_HEX" | python3 -c "
import sys, json
raw = input().strip()
# getData returns ABI-encoded bytes; strip the outer ABI wrapper
# The inner JSON starts after the offset+length prefix (64 bytes each)
if raw.startswith('0x'):
    raw = raw[2:]
# Try to find valid JSON by scanning for '{'
for i in range(0, len(raw)-1, 2):
    try:
        candidate = bytes.fromhex(raw[i:]).decode('utf-8', errors='ignore').strip('\x00')
        # Find first '{' 
        start = candidate.find('{')
        if start >= 0:
            data = json.loads(candidate[start:candidate.rfind('}')+1])
            print(json.dumps(data, indent=2))
            break
    except:
        continue
"

  echo ""
  echo "════════════════════════════════════════"
  success "WEATHER ORACLE END-TO-END COMPLETE!"
  echo "  Trigger:         $TRIGGER_ADDR"
  echo "  ServiceManager:  $SM_ADDR"
  echo "  Submit:          $SUBMIT_ADDR"
  echo "  Service ID:      $SERVICE_ID"
  echo "  Signing key:     $SIGNING_KEY (HD $HD_INDEX)"
  echo "════════════════════════════════════════"
  echo ""
  echo "Fire more queries:"
  echo "  cast send $TRIGGER_ADDR 'addTrigger(string)' 'Tokyo' --private-key $PRIVATE_KEY --rpc-url $RPC_URL"
else
  warn "isValidTriggerId($TRIGGER_ID) = false — WAVS may still be processing"
  warn "Try: cast call $SUBMIT_ADDR 'isValidTriggerId(uint64)(bool)' $TRIGGER_ID --rpc-url $RPC_URL"
  echo ""
  echo "Contract addresses:"
  echo "  TRIGGER_ADDR=$TRIGGER_ADDR"
  echo "  SERVICE_MANAGER_ADDR=$SM_ADDR"
  echo "  SUBMIT_ADDR=$SUBMIT_ADDR"
  echo "  SERVICE_ID=$SERVICE_ID"
  echo "  SIGNING_KEY=$SIGNING_KEY"
fi
