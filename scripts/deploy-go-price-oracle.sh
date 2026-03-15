#!/usr/bin/env bash
# =============================================================================
# deploy-go-price-oracle.sh — Full end-to-end deploy for golang-evm-price-oracle
#
# What it does:
#   1. Uses pre-compiled Go WASM from compiled/golang_evm_price_oracle.wasm
#   2. Builds the aggregator WASM component (Rust)
#   3. Deploys SimpleTrigger, SimpleServiceManager, SimpleSubmit contracts
#   4. Uploads WASM components to the WAVS node
#   5. Registers the service (trigger: NewTrigger on SimpleTrigger)
#   6. Funds the signing key + aggregator credential
#   7. Sets operator weight for the signing key
#   8. Smoke test: submits a price request (CMC ID=1 = Bitcoin), waits for result
#
# Requires:
#   - Anvil at $RPC_URL          (default: http://host.docker.internal:8545)
#   - WAVS node at $WAVS_URL     (default: http://host.docker.internal:8041)
#     with dev_endpoints_enabled = true
#   - forge, cast, cargo-component, curl, python3 in PATH
#
# Notes:
#   - RESTART the WAVS node before running if Anvil was restarted!
#     WAVS persists its last-processed block; a stale cursor will miss events.
#   - The Go component fetches live CoinMarketCap data (no API key required).
#     Pass a CMC ID as the trigger input (1=BTC, 1027=ETH, 5805=AVAX, etc.)
#
# Usage:
#   ./scripts/deploy-go-price-oracle.sh
#   CMC_ID=1027 ./scripts/deploy-go-price-oracle.sh
# =============================================================================
set -euo pipefail

RPC_URL="${RPC_URL:-http://host.docker.internal:8545}"
WAVS_URL="${WAVS_URL:-http://host.docker.internal:8041}"
CHAIN_ID="${CHAIN_ID:-evm:31337}"
PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
CMC_ID="${CMC_ID:-1}"

# Aggregator credential: HD index 0 of WAVS mnemonic (stable, must be funded)
AGG_CREDENTIAL="0xc63aff4f9B0ebD48B6C9814619cAbfD9a7710A58"

GREEN="\033[0;32m"; BLUE="\033[0;34m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; NC="\033[0m"
info()    { echo -e "${BLUE}▶ $*${NC}"; }
success() { echo -e "${GREEN}✅ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
die()     { echo -e "${RED}❌ $*${NC}"; exit 1; }

# =============================================================================
# 1. Check pre-compiled Go WASM
# =============================================================================
GO_WASM="compiled/golang_evm_price_oracle.wasm"
[ -f "$GO_WASM" ] || die "Go WASM not found at $GO_WASM — run: make -C components/golang-evm-price-oracle wasi-build"
info "Using pre-compiled Go WASM: $GO_WASM ($(du -sh "$GO_WASM" | cut -f1))"

# =============================================================================
# 2. Build aggregator WASM
# =============================================================================
info "Building aggregator component..."
AGG_WASM="compiled/aggregator.wasm"
[ -f "$AGG_WASM" ] || die "aggregator.wasm not found at $AGG_WASM"
success "Aggregator: $AGG_WASM"

# =============================================================================
# 3. Deploy contracts
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
# 4. Get NewTrigger event hash
# =============================================================================
info "Computing NewTrigger event hash..."
EVENT_HASH=$(cast keccak "NewTrigger(bytes)")
success "NewTrigger event hash: $EVENT_HASH"

# =============================================================================
# 5. Upload WASM components
# =============================================================================
info "Uploading Go price oracle component..."
GO_DIGEST=$(curl -sf -X POST "$WAVS_URL/dev/components" \
  -H "Content-Type: application/wasm" \
  --data-binary @"$GO_WASM" | python3 -c "import json,sys; print(json.load(sys.stdin)['digest'])")
success "Go price oracle digest: $GO_DIGEST"

info "Uploading aggregator component..."
AGG_DIGEST=$(curl -sf -X POST "$WAVS_URL/dev/components" \
  -H "Content-Type: application/wasm" \
  --data-binary @"$AGG_WASM" | python3 -c "import json,sys; print(json.load(sys.stdin)['digest'])")
success "Aggregator digest: $AGG_DIGEST"

# =============================================================================
# 6. Build and save service definition
# =============================================================================
info "Saving service definition..."

# Export vars so the Python subprocess can read them via os.environ
export SM_ADDR TRIGGER_ADDR SUBMIT_ADDR EVENT_HASH GO_DIGEST AGG_DIGEST CHAIN_ID

# Write to file to avoid bash/Python quoting issues with $CHAIN_ID (contains ':')
python3 - <<PYEOF
import json, os
svc = {
  "name": "golang-evm-price-oracle",
  "status": "active",
  "manager": {"evm": {"chain": os.environ["CHAIN_ID"], "address": os.environ["SM_ADDR"]}},
  "workflows": {
    "default": {
      "trigger": {
        "evm_contract_event": {
          "chain": os.environ["CHAIN_ID"],
          "address": os.environ["TRIGGER_ADDR"],
          "event_hash": os.environ["EVENT_HASH"]
        }
      },
      "component": {
        "source": {"digest": os.environ["GO_DIGEST"]},
        "permissions": {"allowed_http_hosts": "all", "file_system": False, "raw_sockets": False, "dns_resolution": True},
        "env_keys": [], "config": {}
      },
      "submit": {
        "aggregator": {
          "component": {
            "source": {"digest": os.environ["AGG_DIGEST"]},
            "permissions": {"allowed_http_hosts": "all", "file_system": False, "raw_sockets": False, "dns_resolution": True},
            "env_keys": [], "config": {os.environ["CHAIN_ID"]: os.environ["SUBMIT_ADDR"]}
          },
          "signature_kind": {"algorithm": "secp256k1", "prefix": "eip191"}
        }
      }
    }
  }
}
with open("/tmp/go-price-oracle-svc.json", "w") as f:
    json.dump(svc, f)
PYEOF

SERVICE_HASH=$(curl -sf -X POST "$WAVS_URL/dev/services" \
  -H "Content-Type: application/json" \
  -d @/tmp/go-price-oracle-svc.json | python3 -c "import json,sys; print(json.load(sys.stdin)['hash'])")
success "Service saved, hash: $SERVICE_HASH"

# =============================================================================
# 7. Set service URI on-chain
# =============================================================================
info "Setting service URI on-chain..."
SERVICE_URI="http://127.0.0.1:8041/dev/services/$SERVICE_HASH"

cast send "$SM_ADDR" "setServiceURI(string)" "$SERVICE_URI" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --quiet
success "ServiceURI set: $SERVICE_URI"

# =============================================================================
# 8. Register service with WAVS node
# =============================================================================
info "Registering service with WAVS node..."
REG_RESP=$(curl -sf -X POST "$WAVS_URL/services" \
  -H "Content-Type: application/json" \
  -d "{\"service_manager\":{\"evm\":{\"chain\":\"$CHAIN_ID\",\"address\":\"$SM_ADDR\"}}}")
success "Service registered"

# =============================================================================
# 9. Get service ID and signing key
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
# 10. Fund signing key + aggregator credential
# =============================================================================
info "Funding signing key..."
cast send "$SIGNING_KEY" \
  --value 1ether \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --quiet
success "Funded signing key: $SIGNING_KEY"

info "Funding aggregator credential..."
cast send "$AGG_CREDENTIAL" \
  --value 1ether \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --quiet
success "Funded aggregator: $AGG_CREDENTIAL"

# =============================================================================
# 11. Register operator weight
# =============================================================================
info "Setting operator weight..."
cast send "$SM_ADDR" "setOperatorWeight(address,uint256)" "$SIGNING_KEY" 100 \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --quiet
success "setOperatorWeight($SIGNING_KEY, 100)"

# =============================================================================
# 12. Smoke test — fetch price for CMC ID
# =============================================================================
info "Firing price oracle trigger for CMC ID: $CMC_ID"

# Contract increments nextTriggerId BEFORE assigning, so read current value and add 1
TRIGGER_ID=$(( $(cast call "$TRIGGER_ADDR" "nextTriggerId()(uint64)" --rpc-url "$RPC_URL") + 1 ))

cast send "$TRIGGER_ADDR" "addTrigger(string)" "$CMC_ID" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --quiet

echo "Waiting 20 seconds for WAVS to process..."
sleep 20

info "Checking result for trigger ID $TRIGGER_ID..."
IS_VALID=$(cast call "$SUBMIT_ADDR" "isValidTriggerId(uint64)(bool)" "$TRIGGER_ID" --rpc-url "$RPC_URL")

if [ "$IS_VALID" = "true" ]; then
  success "isValidTriggerId($TRIGGER_ID) = true 🎉"

  RESULT_HEX=$(cast call "$SUBMIT_ADDR" "getData(uint64)(bytes)" "$TRIGGER_ID" --rpc-url "$RPC_URL")
  echo ""
  echo "Price oracle result:"
  echo "$RESULT_HEX" | python3 -c "
import sys, json
raw = input().strip()
if raw.startswith('0x'):
    raw = raw[2:]
for i in range(0, len(raw)-1, 2):
    try:
        candidate = bytes.fromhex(raw[i:]).decode('utf-8', errors='ignore').strip('\x00')
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
  success "GO PRICE ORACLE END-TO-END COMPLETE!"
  echo "  Trigger:         $TRIGGER_ADDR"
  echo "  ServiceManager:  $SM_ADDR"
  echo "  Submit:          $SUBMIT_ADDR"
  echo "  Service ID:      $SERVICE_ID"
  echo "  Signing key:     $SIGNING_KEY (HD $HD_INDEX)"
  echo "════════════════════════════════════════"
  echo ""
  echo "Fire more queries:"
  echo "  cast send $TRIGGER_ADDR 'addTrigger(string)' '1027' --private-key \$PRIVATE_KEY --rpc-url $RPC_URL"
  echo "  (1=BTC, 1027=ETH, 5805=AVAX, 74=DOGE)"
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
