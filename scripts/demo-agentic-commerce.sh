#!/usr/bin/env bash
# =============================================================================
# demo-agentic-commerce.sh
#
# End-to-end demo for the ERC-8183 Agentic Commerce example.
# WAVS acts as the trusted evaluator: watches JobSubmitted events, fetches the
# URL from job.description, computes keccak256, and calls complete() or reject().
#
# ERC-8004 reputation is written on job settlement via ReputationHook.
#
# Usage:
#   ./scripts/demo-agentic-commerce.sh
#
# Requires: forge, cast, curl, python3, jq (or python3 fallback)
# Environment: WAVS node + Anvil must be running (see WAVS README)
# =============================================================================
set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR]${NC}   $*"; exit 1; }

# ─── Config ───────────────────────────────────────────────────────────────────
RPC_URL="${RPC_URL:-http://localhost:8545}"
WAVS_URL="${WAVS_URL:-http://localhost:8041}"
CHAIN_ID="${CHAIN_ID:-evm:31337}"
PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
PROVIDER_KEY="${PROVIDER_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"

# Anvil default addresses
DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
PROVIDER=$(cast wallet address --private-key "$PROVIDER_KEY")

# Aggregator credential (HD index 0 of WAVS mnemonic) — must be funded
AGG_CREDENTIAL="0xc63aff4f9B0ebD48B6C9814619cAbfD9a7710A58"

# Service manager address — auto-deploy if not provided
SM_ADDR="${SERVICE_MANAGER_ADDR:-}"
if [ -z "$SM_ADDR" ]; then
  if [ -f ".env" ]; then
    SM_ADDR=$(grep "^SERVICE_MANAGER_ADDR=" .env | cut -d= -f2 | tr -d '"' | tr -d "'")
  fi
fi
if [ -z "$SM_ADDR" ]; then
  info "SERVICE_MANAGER_ADDR not set — deploying SimpleServiceManager..."
  SM_DEPLOY=$(forge create src/contracts/SimpleServiceManager.sol:SimpleServiceManager \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast 2>&1)
  SM_ADDR=$(echo "$SM_DEPLOY" | grep -oE 'Deployed to: (0x[0-9a-fA-F]{40})' | awk '{print $3}')
  [ -z "$SM_ADDR" ] && error "Failed to deploy SimpleServiceManager. Output: $SM_DEPLOY"
  success "SimpleServiceManager deployed: $SM_ADDR"
fi

# Demo job: verify https://httpbin.org/json
DEMO_URL="https://httpbin.org/json"
WAIT_SECS="${WAIT_SECS:-60}"

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  ERC-8183 Agentic Commerce Demo — WAVS as Evaluator  ⚡${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""
info "Deployer:  $DEPLOYER"
info "Provider:  $PROVIDER"
info "RPC:       $RPC_URL"
info "WAVS:      $WAVS_URL"
info "SM:        $SM_ADDR"
echo ""

# =============================================================================
# 1. Deploy contracts
# =============================================================================
info "Deploying Agentic Commerce contracts..."

DEPLOY_OUT=$(SERVICE_MANAGER_ADDR="$SM_ADDR" PROVIDER_ADDR="$PROVIDER" \
  forge script script/DeployAgenticCommerce.s.sol \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --private-key "$PRIVATE_KEY" \
    -vv 2>&1)

echo "$DEPLOY_OUT" | grep -E "^MOCK_TOKEN|^ACP_ADDR|^ACE_ADDR|^HOOK_ADDR|^IDENTITY|^REPUTATION|^PROVIDER" || true

MOCK_TOKEN_ADDR=$(echo "$DEPLOY_OUT" | grep "MOCK_TOKEN_ADDR=" | cut -d= -f2)
ACP_ADDR=$(echo "$DEPLOY_OUT"       | grep "ACP_ADDR=" | cut -d= -f2)
ACE_ADDR=$(echo "$DEPLOY_OUT"       | grep "ACE_ADDR=" | cut -d= -f2)
HOOK_ADDR=$(echo "$DEPLOY_OUT"      | grep "HOOK_ADDR=" | cut -d= -f2)
IDENTITY_REGISTRY=$(echo "$DEPLOY_OUT" | grep "IDENTITY_REGISTRY_ADDR=" | cut -d= -f2)
REPUTATION_REGISTRY=$(echo "$DEPLOY_OUT" | grep "REPUTATION_REGISTRY_ADDR=" | cut -d= -f2)

[ -z "$ACP_ADDR" ] && error "AgenticCommerce deployment failed"
success "AgenticCommerce:         $ACP_ADDR"
success "AgenticCommerceEvaluator: $ACE_ADDR"
success "ReputationHook:          $HOOK_ADDR"
success "IdentityRegistry:        $IDENTITY_REGISTRY"
success "ReputationRegistry:      $REPUTATION_REGISTRY"
success "MockERC20 (tUSDC):       $MOCK_TOKEN_ADDR"

# =============================================================================
# 2. Register provider as ERC-8004 agent
# =============================================================================
info "Registering provider as ERC-8004 agent..."

AGENT_ID_RAW=$(cast send "$IDENTITY_REGISTRY" "register()(uint256)" \
  --rpc-url "$RPC_URL" --private-key "$PROVIDER_KEY" \
  --json | python3 -c "import sys,json; print(json.load(sys.stdin)['logs'][0]['topics'][1])" 2>/dev/null || echo "")

if [ -z "$AGENT_ID_RAW" ]; then
  # Fallback: check getLastId() before and after
  AGENT_ID=$(cast call "$IDENTITY_REGISTRY" "getLastId()(uint256)" --rpc-url "$RPC_URL")
  cast send "$IDENTITY_REGISTRY" "register()" \
    --rpc-url "$RPC_URL" --private-key "$PROVIDER_KEY" --quiet
  AGENT_ID=$(cast call "$IDENTITY_REGISTRY" "getLastId()(uint256)" --rpc-url "$RPC_URL")
  AGENT_ID=$(( AGENT_ID - 1 ))
else
  AGENT_ID=$(python3 -c "print(int('$AGENT_ID_RAW', 16))")
fi

success "Provider ERC-8004 agentId: $AGENT_ID"

# Link provider → agentId in ReputationHook
cast send "$HOOK_ADDR" "registerAgent(address,uint256)" "$PROVIDER" "$AGENT_ID" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
success "Hook: provider linked to agentId $AGENT_ID"

# =============================================================================
# 3. Upload WAVS component
# =============================================================================
info "Building and uploading WAVS component..."

WASM_PATH="target/wasm32-wasip1/release/agentic_commerce_evaluator.wasm"
if [ ! -f "$WASM_PATH" ]; then
  info "Building WASM component..."
  cargo component build -p agentic-commerce-evaluator --release --quiet
fi

EVALUATOR_DIGEST=$(curl -sf -X POST "$WAVS_URL/dev/components" \
  -H "Content-Type: application/wasm" \
  --data-binary "@$WASM_PATH" | python3 -c "import sys,json; print(json.load(sys.stdin)['digest'])")
success "Component uploaded: $EVALUATOR_DIGEST"

# Upload aggregator component
AGG_WASM="target/wasm32-wasip1/release/aggregator.wasm"
if [ ! -f "$AGG_WASM" ]; then
  cargo component build -p aggregator --release --quiet
fi
AGG_DIGEST=$(curl -sf -X POST "$WAVS_URL/dev/components" \
  -H "Content-Type: application/wasm" \
  --data-binary "@$AGG_WASM" | python3 -c "import sys,json; print(json.load(sys.stdin)['digest'])")
success "Aggregator uploaded: $AGG_DIGEST"

# =============================================================================
# 4. Register WAVS service
# =============================================================================
info "Computing JobSubmitted event hash..."
EVENT_HASH=$(cast keccak "JobSubmitted(uint256,address,bytes32)")
success "event_hash: $EVENT_HASH"

info "Building service manifest..."
SERVICE_JSON=$(python3 -c "
import json
print(json.dumps({
  'name': 'agentic-commerce-evaluator',
  'manager': {'evm': {'chain': '$CHAIN_ID', 'address': '$SM_ADDR'}},
  'workflows': {
    'default': {
      'trigger': {
        'evm_contract_event': {
          'chain': '$CHAIN_ID',
          'address': '$ACP_ADDR',
          'event_hash': '$EVENT_HASH'
        }
      },
      'component': {
        'source': {'digest': '$EVALUATOR_DIGEST'},
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
            'config': {'$CHAIN_ID': '$ACE_ADDR'}
          },
          'signature_kind': {'algorithm': 'secp256k1', 'prefix': 'eip191'}
        }
      }
    }
  },
  'status': 'active'
}))
")

SERVICE_HASH=$(echo "$SERVICE_JSON" | curl -sf -X POST "$WAVS_URL/dev/services" \
  -H "Content-Type: application/json" -d @- | python3 -c "import json,sys; print(json.load(sys.stdin)['hash'])")
success "Service manifest saved: $SERVICE_HASH"

# =============================================================================
# 5. Set service URI on-chain + register with WAVS node
# =============================================================================
SERVICE_URI="http://127.0.0.1:8041/dev/services/$SERVICE_HASH"
cast send "$SM_ADDR" "setServiceURI(string)" "$SERVICE_URI" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
success "ServiceURI set on-chain"

REGISTER_RESP=$(curl -sf -X POST "$WAVS_URL/services" \
  -H "Content-Type: application/json" \
  -d "{\"service_manager\":{\"evm\":{\"chain\":\"$CHAIN_ID\",\"address\":\"$SM_ADDR\"}}}")
success "Service registered with WAVS node"
sleep 3

# =============================================================================
# 6. Get signing key + fund it
# =============================================================================
# service_id is now returned directly from POST /services
SERVICE_ID=$(echo "$REGISTER_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['service_id'])" 2>/dev/null || true)

# Fallback: scan /services list (for older node versions without service_id in response)
if [ -z "$SERVICE_ID" ]; then
  SERVICE_ID=$(curl -sf "$WAVS_URL/services" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sm = '$SM_ADDR'.lower()
for i, svc in enumerate(d['services']):
    mgr_addr = svc.get('manager', {}).get('evm', {}).get('address', '').lower()
    if mgr_addr == sm:
        print(d['service_ids'][i])
        break
else:
    print(d['service_ids'][-1])
")
fi

echo ""
echo -e "${BOLD}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│  SERVICE ID: ${GREEN}${SERVICE_ID}${NC}${BOLD}  │${NC}"
echo -e "${BOLD}│  Logs: ${CYAN}${WAVS_URL}/dev/logs/${SERVICE_ID}${NC}${BOLD}  │${NC}"
echo -e "${BOLD}└─────────────────────────────────────────────────────────────┘${NC}"
echo ""

SIGNER_RESP=$(curl -sf -X POST "$WAVS_URL/services/signer" \
  -H "Content-Type: application/json" \
  -d "{\"service_id\":\"$SERVICE_ID\",\"workflow_id\":\"default\",\"service_manager\":{\"evm\":{\"chain\":\"$CHAIN_ID\",\"address\":\"$SM_ADDR\"}}}")

HD_INDEX=$(echo "$SIGNER_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['secp256k1']['hd_index'])")
SIGNING_KEY=$(echo "$SIGNER_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['secp256k1']['evm_address'])")
success "Signing key: $SIGNING_KEY (HD $HD_INDEX)"

cast send "$SIGNING_KEY" --value 1ether --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
cast send "$AGG_CREDENTIAL" --value 1ether --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
cast send "$SM_ADDR" "setOperatorWeight(address,uint256)" "$SIGNING_KEY" 100 \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
success "Operator funded and weighted"

# =============================================================================
# 7. Demo: create job → fund → provider submits → WAVS evaluates
# =============================================================================
echo ""
echo -e "${BOLD}── Demo Flow ────────────────────────────────────────────────────${NC}"
echo ""
info "Demo URL: $DEMO_URL"

BUDGET="100000000"  # 100 tUSDC (6 decimals)
NO_EXPIRY="0"

# Compute the correct deliverable: keccak256 of the URL's response body.
# IMPORTANT: pipe directly to cast keccak — do NOT capture via $() first!
# Bash $() strips trailing newlines, which would produce a different hash than
# the WAVS component (which hashes the raw HTTP bytes including any trailing newline).
info "Pre-fetching URL to compute correct deliverable..."
CORRECT_DELIVERABLE=$(curl -sf "$DEMO_URL" | cast keccak)
info "Correct deliverable: $CORRECT_DELIVERABLE"

# Client approves AgenticCommerce to spend tUSDC
cast send "$MOCK_TOKEN_ADDR" "approve(address,uint256)" "$ACP_ADDR" "$BUDGET" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet

# Create job (client = deployer, provider = PROVIDER, evaluator = ACE)
JOB_COUNT_BEFORE=$(cast call "$ACP_ADDR" "getJobCount()(uint256)" --rpc-url "$RPC_URL")
cast send "$ACP_ADDR" \
  "createJob(address,address,uint64,string,address)(uint256)" \
  "$PROVIDER" "$ACE_ADDR" "$NO_EXPIRY" "$DEMO_URL" "$HOOK_ADDR" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet

JOB_ID=$(cast call "$ACP_ADDR" "getJobCount()(uint256)" --rpc-url "$RPC_URL")
success "Job created: jobId=$JOB_ID"

# Set budget + fund
cast send "$ACP_ADDR" "setBudget(uint256,uint256)" "$JOB_ID" "$BUDGET" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
cast send "$ACP_ADDR" "fund(uint256,uint256)" "$JOB_ID" "$BUDGET" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
success "Job funded: $BUDGET tUSDC in escrow"

PROVIDER_BALANCE_BEFORE=$(cast call "$MOCK_TOKEN_ADDR" "balanceOf(address)(uint256)" \
  "$PROVIDER" --rpc-url "$RPC_URL")
info "Provider balance before: $PROVIDER_BALANCE_BEFORE tUSDC (raw)"

# Provider submits — this fires JobSubmitted → WAVS wakes up!
info "Provider submitting deliverable (keccak256 of '$DEMO_URL' response)..."
cast send "$ACP_ADDR" "submit(uint256,bytes32)" "$JOB_ID" "$CORRECT_DELIVERABLE" \
  --rpc-url "$RPC_URL" --private-key "$PROVIDER_KEY" --quiet
success "JobSubmitted event fired! WAVS evaluator watching..."

# =============================================================================
# 8. Wait for WAVS to evaluate
# =============================================================================
info "Waiting ${WAIT_SECS}s for WAVS to process..."
sleep "$WAIT_SECS"

# =============================================================================
# 9. Check result
# =============================================================================
echo ""
echo -e "${BOLD}── Results ─────────────────────────────────────────────────────${NC}"
echo ""

JOB_DATA=$(cast call "$ACP_ADDR" "getJob(uint256)((address,address,address,address,string,uint256,uint64,uint8))" \
  "$JOB_ID" --rpc-url "$RPC_URL")

# Status: 0=Open 1=Funded 2=Submitted 3=Completed 4=Rejected 5=Expired
STATUS=$(echo "$JOB_DATA" | python3 -c "
import sys, re
data = sys.stdin.read()
# Extract last tuple element (status uint8)
nums = re.findall(r'\d+', data)
if nums: print(nums[-1])
else: print('?')
" 2>/dev/null || echo "?")

PROVIDER_BALANCE_AFTER=$(cast call "$MOCK_TOKEN_ADDR" "balanceOf(address)(uint256)" \
  "$PROVIDER" --rpc-url "$RPC_URL")

info "Job status raw: $STATUS (3=Completed, 4=Rejected)"
info "Provider balance after: $PROVIDER_BALANCE_AFTER tUSDC (raw)"

# Check ERC-8004 reputation
REP_COUNT=$(cast call "$REPUTATION_REGISTRY" \
  "getSummary(uint256,address[],string,string)(uint64,int128,uint8)" \
  "$AGENT_ID" "[]" "" "" --rpc-url "$RPC_URL" | awk 'NR==1{print $1}' 2>/dev/null || echo "?")

case "$STATUS" in
  3)
    echo ""
    echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
    success "JOB COMPLETED! ⚡ ERC-8183 settlement verified"
    echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
    echo ""
    info "  AgenticCommerce:          $ACP_ADDR"
    info "  AgenticCommerceEvaluator: $ACE_ADDR"
    info "  Job ID:                   $JOB_ID"
    info "  Provider paid:            $BUDGET tUSDC (raw)"
    info "  ERC-8004 feedback count:  $REP_COUNT"
    info "  Service ID:               $SERVICE_ID"
    ;;
  4)
    warn "Job REJECTED (WAVS computed hash didn't match deliverable)"
    warn "This is correct behaviour — client refunded, provider not paid"
    ;;
  2)
    warn "Job still in Submitted state — WAVS may still be processing"
    warn "Try: cast call $ACP_ADDR 'getJob(uint256)' $JOB_ID --rpc-url $RPC_URL"
    ;;
  *)
    warn "Unexpected job status: $STATUS"
    ;;
esac

echo ""
echo "To inspect the job:"
echo "  cast call $ACP_ADDR 'getJob(uint256)' $JOB_ID --rpc-url $RPC_URL"
echo ""
echo "To check ERC-8004 reputation:"
echo "  cast call $REPUTATION_REGISTRY 'getSummary(uint256,address[],string,string)' $AGENT_ID '[]' '' '' --rpc-url $RPC_URL"
echo ""
