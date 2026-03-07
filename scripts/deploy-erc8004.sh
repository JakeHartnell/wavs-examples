#!/usr/bin/env bash
# =============================================================================
# deploy-erc8004.sh — Full end-to-end deploy for the ERC-8004 WAVS validator
#
# What it does:
#   1. Builds erc8004-validator + aggregator WASM components
#   2. Deploys ValidationTrigger, SimpleServiceManager, ValidationSubmit contracts
#   3. Uploads WASM components to the WAVS node
#   4. Registers the service (trigger: NewTrigger on ValidationTrigger)
#   5. Sets operator weight for the signing key
#   6. Smoke test: submits a validation request, waits for result
#
# Requires:
#   - Anvil at $RPC_URL          (default: http://localhost:8545)
#   - WAVS node at $WAVS_URL     (default: http://localhost:8041)
#     with dev_endpoints_enabled = true
#   - forge, cast, cargo-component, curl, python3 in PATH
#
# Notes:
#   - allowed_http_hosts must be "all" | "none" | {"only": [...]}  (not "*")
#   - /dev/services POST requires "status" and "manager" fields
#   - WAVS watches events from the block the service is registered,
#     so fire the smoke test AFTER registration completes
#
# Usage:
#   ./scripts/deploy-erc8004.sh
#   WAVS_URL=http://host.docker.internal:8041 RPC_URL=http://host.docker.internal:8545 ./scripts/deploy-erc8004.sh
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
cargo component build --release -p erc8004-validator -p aggregator \
  --target wasm32-wasip1 2>&1 | grep -E "Compiling erc|Compiling agg|Finished|Creating|error"
success "Components built"

VALIDATOR_WASM="target/wasm32-wasip1/release/erc8004_validator.wasm"
AGG_WASM="target/wasm32-wasip1/release/aggregator.wasm"
[ -f "$VALIDATOR_WASM" ] || die "erc8004_validator.wasm not found at $VALIDATOR_WASM"
[ -f "$AGG_WASM" ]       || die "aggregator.wasm not found at $AGG_WASM"

# =============================================================================
# 2. Deploy contracts
# =============================================================================
info "Deploying contracts via forge..."

DEPLOY_OUT=$(forge script script/DeployErc8004.s.sol \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --private-key "$PRIVATE_KEY" \
  2>&1)

TRIGGER_ADDR=$(echo "$DEPLOY_OUT" | grep "TRIGGER_ADDR="         | tail -1 | cut -d= -f2 | tr -d ' ')
SM_ADDR=$(echo "$DEPLOY_OUT"      | grep "SERVICE_MANAGER_ADDR=" | tail -1 | cut -d= -f2 | tr -d ' ')
SUBMIT_ADDR=$(echo "$DEPLOY_OUT"  | grep "SUBMIT_ADDR="          | tail -1 | cut -d= -f2 | tr -d ' ')

[ -n "$TRIGGER_ADDR" ] || die "Failed to parse TRIGGER_ADDR from forge output:\n$DEPLOY_OUT"
[ -n "$SM_ADDR" ]      || die "Failed to parse SERVICE_MANAGER_ADDR"
[ -n "$SUBMIT_ADDR" ]  || die "Failed to parse SUBMIT_ADDR"

success "Contracts deployed"
echo "  ValidationTrigger:    $TRIGGER_ADDR"
echo "  SimpleServiceManager: $SM_ADDR"
echo "  ValidationSubmit:     $SUBMIT_ADDR"

# =============================================================================
# 3. Compute NewTrigger event hash
# =============================================================================
info "Computing NewTrigger event hash..."
EVENT_HASH=$(cast keccak "NewTrigger(bytes)")
success "NewTrigger event hash: $EVENT_HASH"

# =============================================================================
# 4. Upload WASM components
# =============================================================================
info "Uploading erc8004-validator component..."
VALIDATOR_DIGEST=$(curl -sf -X POST "$WAVS_URL/dev/components" \
  -H "Content-Type: application/wasm" \
  --data-binary @"$VALIDATOR_WASM" | python3 -c "import json,sys; print(json.load(sys.stdin)['digest'])")
success "Validator digest: $VALIDATOR_DIGEST"

info "Uploading aggregator component..."
AGG_DIGEST=$(curl -sf -X POST "$WAVS_URL/dev/components" \
  -H "Content-Type: application/wasm" \
  --data-binary @"$AGG_WASM" | python3 -c "import json,sys; print(json.load(sys.stdin)['digest'])")
success "Aggregator digest: $AGG_DIGEST"

# =============================================================================
# 5. Build and save service JSON
#
# IMPORTANT: /dev/services POST requires "status" and "manager" fields.
# allowed_http_hosts must be "all" | "none" | {"only": [...]}  (not "*")
# =============================================================================
info "Saving service definition..."

SERVICE_JSON=$(python3 -c "
import json
print(json.dumps({
  'name': 'erc8004-validator',
  'status': 'active',
  'manager': {
    'evm': {'chain': '$CHAIN_ID', 'address': '$SM_ADDR'}
  },
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
        'source': {'digest': '$VALIDATOR_DIGEST'},
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
# URI must use 127.0.0.1 (not localhost / host.docker.internal) — the WAVS
# node fetches this from within the host, not from inside the container
# =============================================================================
info "Setting service URI on-chain..."
SERVICE_URI="http://127.0.0.1:8041/dev/services/$SERVICE_HASH"
cast send "$SM_ADDR" "setServiceURI(string)" "$SERVICE_URI" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
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

sleep 3  # Let node assign HD index

# =============================================================================
# 8. Get service ID and signing key
# =============================================================================
info "Fetching service ID and signing key..."

SERVICE_ID=$(curl -sf "$WAVS_URL/services" | python3 -c "
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
# 9. Fund signing key AND aggregator credential
#
# Two accounts need ETH:
#   - SIGNING_KEY  (HD index N of WAVS mnemonic) — signs submitted results
#   - AGGREGATOR   (HD index 0 of WAVS mnemonic) — pays gas for on-chain submits
#
# IMPORTANT: Failure to fund the aggregator causes silent failures — the
# component will run and produce a result, but the aggregator can't submit it.
# =============================================================================
info "Funding signing key..."
cast send "$SIGNING_KEY" --value 1ether \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
success "Funded $SIGNING_KEY with 1 ETH"

info "Funding aggregator credential (HD index 0 of WAVS mnemonic)..."
AGG_CREDENTIAL="0xc63aff4f9B0ebD48B6C9814619cAbfD9a7710A58"
cast send "$AGG_CREDENTIAL" --value 1ether \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
success "Funded aggregator $AGG_CREDENTIAL with 1 ETH"

# =============================================================================
# 10. Set operator weight
# =============================================================================
info "Setting operator weight..."
cast send "$SM_ADDR" "setOperatorWeight(address,uint256)" "$SIGNING_KEY" 100 \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
success "setOperatorWeight($SIGNING_KEY, 100)"

# =============================================================================
# 11. Smoke test — fire trigger AFTER service is registered and watching
#
# The WAVS node only sees events from the block it started watching. Fire the
# trigger AFTER all setup is complete to ensure it's picked up.
#
# URL: https://httpbin.org/base64/SGVsbG8gV0FWUw== → returns "Hello WAVS"
# We don't pre-commit the hash; the validator will compute it and the submit
# contract stores it for comparison.
# =============================================================================
info "Firing smoke test trigger..."
info "Note: trigger must be fired AFTER service is registered — WAVS misses earlier blocks"

TEST_URL="https://httpbin.org/base64/SGVsbG8gV0FWUw=="
# keccak256("Hello WAVS") — pre-computed. Verify with: cast keccak "Hello WAVS"
TEST_HASH=$(cast keccak "Hello WAVS")
info "  URL:  $TEST_URL"
info "  Hash: $TEST_HASH (keccak256 of expected response)"

cast send "$TRIGGER_ADDR" "requestValidation(string,bytes32)" \
  "$TEST_URL" "$TEST_HASH" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet

TRIGGER_ID=$(cast call "$TRIGGER_ADDR" "nextTriggerId()(uint64)" --rpc-url "$RPC_URL")
info "Trigger ID: $TRIGGER_ID — waiting 30s for WAVS to process..."
sleep 30

# =============================================================================
# 12. Check result
# =============================================================================
info "Checking result..."
IS_COMPLETE=$(cast call "$SUBMIT_ADDR" "isComplete(uint64)(bool)" "$TRIGGER_ID" --rpc-url "$RPC_URL")

if [ "$IS_COMPLETE" = "true" ]; then
  RESULT=$(cast call "$SUBMIT_ADDR" "getResult(uint64)((bytes32,uint8,string,address,uint256,bool))" \
    "$TRIGGER_ID" --rpc-url "$RPC_URL")
  success "Validation complete! isComplete($TRIGGER_ID) = true"
  echo "  Result: $RESULT"
  echo ""
  echo "════════════════════════════════════════"
  success "FULL END-TO-END COMPLETE! ⚡"
  echo "  ValidationTrigger:    $TRIGGER_ADDR"
  echo "  ServiceManager:       $SM_ADDR"
  echo "  ValidationSubmit:     $SUBMIT_ADDR"
  echo "  Service ID:           $SERVICE_ID"
  echo "  Signing key:          $SIGNING_KEY (HD $HD_INDEX)"
  echo "════════════════════════════════════════"
  echo ""
  echo "  To submit your own validation request:"
  echo "  cast send $TRIGGER_ADDR 'requestValidation(string,bytes32)' \\"
  echo "    '<uri>' \"\$(cast keccak '<expected-content>')\" \\"
  echo "    --rpc-url $RPC_URL --private-key \$PRIVATE_KEY"
else
  warn "isComplete($TRIGGER_ID) = false — WAVS may still be processing"
  warn "If still false after 60s, check WAVS node logs for errors"
  echo ""
  echo "  Manual check:"
  echo "  cast call $SUBMIT_ADDR 'isComplete(uint64)(bool)' $TRIGGER_ID --rpc-url $RPC_URL"
  echo ""
  echo "Contract addresses:"
  echo "  TRIGGER_ADDR=$TRIGGER_ADDR"
  echo "  SERVICE_MANAGER_ADDR=$SM_ADDR"
  echo "  SUBMIT_ADDR=$SUBMIT_ADDR"
  echo "  SERVICE_ID=$SERVICE_ID"
  echo "  SIGNING_KEY=$SIGNING_KEY"
fi
