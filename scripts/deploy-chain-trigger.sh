#!/usr/bin/env bash
# =============================================================================
# deploy-chain-trigger.sh — End-to-end test for HTTP trigger chaining
#
# Deploys two WAVS services:
#   chain-responder  — the callee: receives bytes, stores in KV
#   chain-caller     — the orchestrator: fires chain-responder via HTTP,
#                      reads back KV result, returns composite JSON
#
# Both services use submit:none (no on-chain result). Verification is via
# WAVS dev endpoints: /dev/logs/{service_id} and /dev/kv/{service_id}/...
#
# Requires:
#   - Anvil running at $RPC_URL (default: http://localhost:8545)
#   - WAVS node running at $WAVS_URL with dev_endpoints_enabled = true
#   - forge, cast, cargo-component in PATH
#
# Usage:
#   cd /home/node/.openclaw/workspace/wavs-examples
#   ./scripts/deploy-chain-trigger.sh
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

RPC_URL="${RPC_URL:-http://localhost:8545}"
WAVS_URL="${WAVS_URL:-http://host.docker.internal:8041}"
CHAIN_ID="${CHAIN_ID:-evm:31337}"
PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
TEST_MESSAGE="${TEST_MESSAGE:-Hello from chain-caller! Can you hear me, chain-responder?}"

GREEN="\033[0;32m"; BLUE="\033[0;34m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; NC="\033[0m"
info()    { echo -e "${BLUE}▶ $*${NC}"; }
success() { echo -e "${GREEN}✅ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠  $*${NC}"; }
die()     { echo -e "${RED}❌ $*${NC}"; exit 1; }

# =============================================================================
# 1. Build WASMs
# =============================================================================
info "Building chain-responder..."
# Remove stale artifacts to avoid cargo copy-to-release failures
rm -f target/wasm32-wasip1/release/deps/chain_responder.wasm
cargo component build --release -p chain-responder --target wasm32-wasip1 \
  2>&1 | grep -E "Compiling|Finished|Creating|error\[|warning\["

info "Building chain-caller..."
rm -f target/wasm32-wasip1/release/deps/chain_caller.wasm
cargo component build --release -p chain-caller --target wasm32-wasip1 \
  2>&1 | grep -E "Compiling|Finished|Creating|error\[|warning\["

RESPONDER_WASM="target/wasm32-wasip1/release/chain_responder.wasm"
CALLER_WASM="target/wasm32-wasip1/release/chain_caller.wasm"

[ -f "$RESPONDER_WASM" ] || die "chain_responder.wasm not found"
[ -f "$CALLER_WASM" ]    || die "chain_caller.wasm not found"
success "Both WASMs built"

# =============================================================================
# 2. Deploy service manager contracts
# =============================================================================
info "Deploying SimpleServiceManager contracts (2x) via forge..."

FORGE_OUT=$(forge script script/DeployChainTrigger.s.sol \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --private-key "$PRIVATE_KEY" \
  2>&1)

echo "$FORGE_OUT" | tail -15

RESPONDER_SM=$(echo "$FORGE_OUT" | grep "RESPONDER_SM_ADDR=" | tail -1 | cut -d= -f2 | tr -d ' ')
CALLER_SM=$(echo "$FORGE_OUT"    | grep "CALLER_SM_ADDR="    | tail -1 | cut -d= -f2 | tr -d ' ')

[ -n "$RESPONDER_SM" ] || die "Failed to parse RESPONDER_SM_ADDR"
[ -n "$CALLER_SM" ]    || die "Failed to parse CALLER_SM_ADDR"

success "Contracts deployed"
echo "  ResponderSM: $RESPONDER_SM"
echo "  CallerSM:    $CALLER_SM"

# =============================================================================
# 3. Upload WASMs to WAVS
# =============================================================================
info "Uploading chain-responder WASM..."
RESPONDER_DIGEST=$(curl -sf -X POST "$WAVS_URL/dev/components" \
  -H "Content-Type: application/wasm" \
  --data-binary @"$RESPONDER_WASM" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['digest'])")
success "chain-responder digest: $RESPONDER_DIGEST"

info "Uploading chain-caller WASM..."
CALLER_DIGEST=$(curl -sf -X POST "$WAVS_URL/dev/components" \
  -H "Content-Type: application/wasm" \
  --data-binary @"$CALLER_WASM" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['digest'])")
success "chain-caller digest: $CALLER_DIGEST"

# =============================================================================
# 4. Register chain-responder service
# =============================================================================
info "Registering chain-responder service..."

RESPONDER_SERVICE_JSON=$(python3 -c "
import json
print(json.dumps({
  'name': 'chain-responder',
  'status': 'active',
  'manager': {'evm': {'chain': '$CHAIN_ID', 'address': '$RESPONDER_SM'}},
  'workflows': {
    'default': {
      'trigger': 'manual',
      'component': {
        'source': {'digest': '$RESPONDER_DIGEST'},
        'permissions': {
          'allowed_http_hosts': 'none',
          'file_system': False,
          'raw_sockets': False,
          'dns_resolution': False
        },
        'env_keys': [],
        'config': {},
        'time_limit_seconds': 30
      },
      'submit': 'none'
    }
  }
}))
")

RESPONDER_HASH=$(echo "$RESPONDER_SERVICE_JSON" | curl -sf -X POST "$WAVS_URL/dev/services" \
  -H "Content-Type: application/json" \
  -d @- \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['hash'])")
success "chain-responder service hash: $RESPONDER_HASH"

RESPONDER_URI="http://127.0.0.1:8041/dev/services/$RESPONDER_HASH"
cast send "$RESPONDER_SM" "setServiceURI(string)" "$RESPONDER_URI" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
success "setServiceURI → $RESPONDER_URI"

RESP_REG=$(curl -sf -X POST "$WAVS_URL/services" \
  -H "Content-Type: application/json" \
  -d "{\"service_manager\":{\"evm\":{\"chain\":\"$CHAIN_ID\",\"address\":\"$RESPONDER_SM\"}}}")
success "chain-responder registered with WAVS"

# WAVS v1.1+ returns service_id directly
RESPONDER_SERVICE_ID=$(echo "$RESP_REG" | python3 -c "import json,sys; print(json.load(sys.stdin)['service_id'])" 2>/dev/null) || true
if [ -z "$RESPONDER_SERVICE_ID" ]; then
  sleep 3
  RESPONDER_SERVICE_ID=$(curl -sf "$WAVS_URL/services" | python3 -c "
import json,sys
ids = json.load(sys.stdin).get('service_ids', [])
if not ids: raise SystemExit('No services found')
print(ids[-1])
")
fi
success "chain-responder service ID: $RESPONDER_SERVICE_ID"

# Get and fund signing key
SIGNER_RESP=$(curl -sf -X POST "$WAVS_URL/services/signer" \
  -H "Content-Type: application/json" \
  -d "{\"service_id\":\"$RESPONDER_SERVICE_ID\",\"workflow_id\":\"default\",\"service_manager\":{\"evm\":{\"chain\":\"$CHAIN_ID\",\"address\":\"$RESPONDER_SM\"}}}")
RESPONDER_SIGNER=$(echo "$SIGNER_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['secp256k1']['evm_address'])")
RESPONDER_HD=$(echo "$SIGNER_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['secp256k1']['hd_index'])")

cast send "$RESPONDER_SIGNER" --value 0.1ether \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
cast send "$RESPONDER_SM" "setOperatorWeight(address,uint256)" "$RESPONDER_SIGNER" 100 \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet

success "chain-responder signer: $RESPONDER_SIGNER (HD $RESPONDER_HD)"

# =============================================================================
# 5. Register chain-caller service (with callee_service_id config)
# =============================================================================
info "Registering chain-caller service (callee_service_id=$RESPONDER_SERVICE_ID)..."

CALLER_SERVICE_JSON=$(python3 -c "
import json
print(json.dumps({
  'name': 'chain-caller',
  'status': 'active',
  'manager': {'evm': {'chain': '$CHAIN_ID', 'address': '$CALLER_SM'}},
  'workflows': {
    'default': {
      'trigger': 'manual',
      'component': {
        'source': {'digest': '$CALLER_DIGEST'},
        'permissions': {
          'allowed_http_hosts': 'all',
          'file_system': False,
          'raw_sockets': False,
          'dns_resolution': True
        },
        'env_keys': [],
        'config': {
          'callee_service_id': '$RESPONDER_SERVICE_ID',
          'callee_workflow_id': 'default',
          'wavs_node_url': 'http://host.docker.internal:8041'
        },
        'time_limit_seconds': 60
      },
      'submit': 'none'
    }
  }
}))
")

CALLER_HASH=$(echo "$CALLER_SERVICE_JSON" | curl -sf -X POST "$WAVS_URL/dev/services" \
  -H "Content-Type: application/json" \
  -d @- \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['hash'])")
success "chain-caller service hash: $CALLER_HASH"

CALLER_URI="http://127.0.0.1:8041/dev/services/$CALLER_HASH"
cast send "$CALLER_SM" "setServiceURI(string)" "$CALLER_URI" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
success "setServiceURI → $CALLER_URI"

CALLER_REG=$(curl -sf -X POST "$WAVS_URL/services" \
  -H "Content-Type: application/json" \
  -d "{\"service_manager\":{\"evm\":{\"chain\":\"$CHAIN_ID\",\"address\":\"$CALLER_SM\"}}}")
success "chain-caller registered with WAVS"

# WAVS v1.1+ returns service_id directly
CALLER_SERVICE_ID=$(echo "$CALLER_REG" | python3 -c "import json,sys; print(json.load(sys.stdin)['service_id'])" 2>/dev/null) || true
if [ -z "$CALLER_SERVICE_ID" ]; then
  sleep 3
  CALLER_SERVICE_ID=$(curl -sf "$WAVS_URL/services" | python3 -c "
import json,sys
ids = json.load(sys.stdin).get('service_ids', [])
if not ids: raise SystemExit('No services found')
print(ids[-1])
")
fi
success "chain-caller service ID: $CALLER_SERVICE_ID"

SIGNER_RESP=$(curl -sf -X POST "$WAVS_URL/services/signer" \
  -H "Content-Type: application/json" \
  -d "{\"service_id\":\"$CALLER_SERVICE_ID\",\"workflow_id\":\"default\",\"service_manager\":{\"evm\":{\"chain\":\"$CHAIN_ID\",\"address\":\"$CALLER_SM\"}}}")
CALLER_SIGNER=$(echo "$SIGNER_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['secp256k1']['evm_address'])")
CALLER_HD=$(echo "$SIGNER_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['secp256k1']['hd_index'])")

cast send "$CALLER_SIGNER" --value 0.1ether \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
cast send "$CALLER_SM" "setOperatorWeight(address,uint256)" "$CALLER_SIGNER" 100 \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet

success "chain-caller signer: $CALLER_SIGNER (HD $CALLER_HD)"

# =============================================================================
# 6. Fire chain-caller!
# =============================================================================
info "Firing chain-caller with test message: \"$TEST_MESSAGE\""

# Build byte array for TriggerData::Raw
MSG_BYTES=$(python3 -c "
msg = '$TEST_MESSAGE'
import json
arr = [b for b in msg.encode('utf-8')]
print(json.dumps(arr))
")

TRIGGER_PAYLOAD=$(python3 -c "
import json
msg_bytes = $MSG_BYTES
print(json.dumps({
  'service_id': '$CALLER_SERVICE_ID',
  'workflow_id': 'default',
  'trigger': 'manual',
  'data': {'Raw': msg_bytes},
  'count': 1,
  'wait_for_completion': True
}))
")

info "POST $WAVS_URL/dev/triggers (wait_for_completion=true)..."
TRIGGER_RESP=$(echo "$TRIGGER_PAYLOAD" | curl -sf -X POST "$WAVS_URL/dev/triggers" \
  -H "Content-Type: application/json" \
  -d @-)
echo "  Trigger response: $TRIGGER_RESP"
success "Trigger fired!"

# =============================================================================
# 7. Verify: logs + KV
# =============================================================================
info "Fetching chain-responder logs..."
RESPONDER_LOGS=$(curl -sf "$WAVS_URL/dev/logs/$RESPONDER_SERVICE_ID" 2>/dev/null || echo "[]")
echo "$RESPONDER_LOGS" | python3 -c "
import json,sys
logs = json.load(sys.stdin)
if not logs:
    print('  (no logs yet)')
else:
    for entry in logs[-10:]:
        level = entry.get('level','?')
        msg   = entry.get('message','')
        print(f'  [{level}] {msg}')
" 2>/dev/null || echo "  (logs not available or empty)"

info "Fetching chain-caller logs..."
CALLER_LOGS=$(curl -sf "$WAVS_URL/dev/logs/$CALLER_SERVICE_ID" 2>/dev/null || echo "[]")
echo "$CALLER_LOGS" | python3 -c "
import json,sys
logs = json.load(sys.stdin)
if not logs:
    print('  (no logs yet)')
else:
    for entry in logs[-10:]:
        level = entry.get('level','?')
        msg   = entry.get('message','')
        print(f'  [{level}] {msg}')
" 2>/dev/null || echo "  (logs not available or empty)"

info "Fetching KV store: chain-responder chain/output..."
KV_RESP=$(curl -sf "$WAVS_URL/dev/kv/$RESPONDER_SERVICE_ID/chain/output" 2>/dev/null || echo "")
if [ -n "$KV_RESP" ]; then
  KV_UTF8=$(echo -n "$KV_RESP" | python3 -c "import sys; data=sys.stdin.buffer.read(); print(data.decode('utf-8','replace'))" 2>/dev/null || echo "$KV_RESP")
  success "KV output: $KV_UTF8"
else
  warn "KV store is empty (chain-responder may not have run yet)"
fi

# =============================================================================
# 8. Summary
# =============================================================================
echo ""
echo "════════════════════════════════════════"
success "CHAIN TRIGGER DEPLOY COMPLETE"
echo ""
echo "  chain-responder:"
echo "    Service ID:  $RESPONDER_SERVICE_ID"
echo "    Signer:      $RESPONDER_SIGNER (HD $RESPONDER_HD)"
echo "    SM contract: $RESPONDER_SM"
echo ""
echo "  chain-caller:"
echo "    Service ID:  $CALLER_SERVICE_ID"
echo "    Signer:      $CALLER_SIGNER (HD $CALLER_HD)"
echo "    SM contract: $CALLER_SM"
echo ""
echo "  Test message: \"$TEST_MESSAGE\""
echo ""
echo "  To fire again:"
echo "    MSG=\"your message here\""
echo "    MSG_BYTES=\$(python3 -c \"import json; print(json.dumps([b for b in '\$MSG'.encode()]))\")"
echo "    curl -X POST $WAVS_URL/dev/triggers -H 'Content-Type: application/json' -d \"{\\\"service_id\\\":\\\"$CALLER_SERVICE_ID\\\",\\\"workflow_id\\\":\\\"default\\\",\\\"trigger\\\":\\\"manual\\\",\\\"data\\\":{\\\"Raw\\\":\$MSG_BYTES},\\\"count\\\":1,\\\"wait_for_completion\\\":true}\""
echo ""
echo "  To inspect:"
echo "    Caller  logs: curl $WAVS_URL/dev/logs/$CALLER_SERVICE_ID | python3 -m json.tool"
echo "    Responder KV: curl $WAVS_URL/dev/kv/$RESPONDER_SERVICE_ID/chain/output"
echo "════════════════════════════════════════"
