#!/usr/bin/env bash
# =============================================================================
# demo-agentic-commerce.sh
#
# Full autonomous ERC-8183 Agentic Commerce demo — two WAVS services:
#
#   1. agentic-commerce-worker   — watches JobFunded events on AgenticCommerce,
#      fetches the job URL, hashes the body, and calls submitWithResult() via
#      AgenticCommerceWorker.sol (the autonomous provider).
#
#   2. agentic-commerce-evaluator — watches JobSubmitted events, re-fetches the
#      same URL, verifies the hash matches the deliverable, and calls complete()
#      or reject() via AgenticCommerceEvaluator.sol.
#
# ERC-8004 reputation is written on job settlement via ReputationHook.
#
# Flow:
#   client createJob → fund → [JobFunded] → worker WAVS → submitWithResult
#   → [JobSubmitted] → evaluator WAVS → complete() → provider paid ⚡
#
# Usage:
#   ./scripts/demo-agentic-commerce.sh
#
# Requires: forge, cast, curl, python3
# Environment: WAVS node + Anvil must be running
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

# Helper: deploy a SimpleServiceManager; echoes address to stdout
deploy_sm_contract() {
  local label="$1"
  local out
  out=$(forge create src/contracts/SimpleServiceManager.sol:SimpleServiceManager \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast 2>&1)
  local addr
  addr=$(echo "$out" | grep -oE 'Deployed to: (0x[0-9a-fA-F]{40})' | awk '{print $3}')
  [ -z "$addr" ] && { error "Failed to deploy $label SM"; }
  success "$label SM deployed: $addr" >&2
  echo "$addr"
}

# Deploy two separate service managers:
# - WORKER_SM   → used by AgenticCommerceWorker.sol for validate()
# - EVALUATOR_SM → used by AgenticCommerceEvaluator.sol for validate()
# Each WAVS service also registers against its own SM.
info "Deploying service managers (worker + evaluator)..."
WORKER_SM_ADDR=$(deploy_sm_contract "Worker")
EVALUATOR_SM_ADDR=$(deploy_sm_contract "Evaluator")


# Demo job: verify https://httpbin.org/json
DEMO_URL="https://httpbin.org/json"
WAIT_SECS="${WAIT_SECS:-60}"

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  ERC-8183 Agentic Commerce Demo — WAVS as Evaluator  ⚡${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""
info "Deployer:     $DEPLOYER"
info "Provider:     $PROVIDER"
info "RPC:          $RPC_URL"
info "WAVS:         $WAVS_URL"
info "Worker SM:    $WORKER_SM_ADDR"
info "Evaluator SM: $EVALUATOR_SM_ADDR"
echo ""

# =============================================================================
# 1. Deploy contracts
# =============================================================================
info "Deploying Agentic Commerce contracts..."

DEPLOY_OUT=$(SERVICE_MANAGER_ADDR="$WORKER_SM_ADDR" \
  WORKER_SM_ADDR="$WORKER_SM_ADDR" \
  EVALUATOR_SM_ADDR="$EVALUATOR_SM_ADDR" \
  PROVIDER_ADDR="$PROVIDER" \
  forge script script/DeployAgenticCommerce.s.sol \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --private-key "$PRIVATE_KEY" \
    -vv 2>&1)

echo "$DEPLOY_OUT" | grep -E "^MOCK_TOKEN|^ACP_ADDR|^ACE_ADDR|^HOOK_ADDR|^IDENTITY|^REPUTATION|^PROVIDER" || true

MOCK_TOKEN_ADDR=$(echo "$DEPLOY_OUT" | grep "MOCK_TOKEN_ADDR=" | cut -d= -f2)
ACP_ADDR=$(echo "$DEPLOY_OUT"       | grep "ACP_ADDR=" | cut -d= -f2)
ACE_ADDR=$(echo "$DEPLOY_OUT"       | grep "ACE_ADDR=" | cut -d= -f2)
ACW_ADDR=$(echo "$DEPLOY_OUT"       | grep "ACW_ADDR=" | cut -d= -f2)
HOOK_ADDR=$(echo "$DEPLOY_OUT"      | grep "HOOK_ADDR=" | cut -d= -f2)
IDENTITY_REGISTRY=$(echo "$DEPLOY_OUT" | grep "IDENTITY_REGISTRY_ADDR=" | cut -d= -f2)
REPUTATION_REGISTRY=$(echo "$DEPLOY_OUT" | grep "REPUTATION_REGISTRY_ADDR=" | cut -d= -f2)

[ -z "$ACP_ADDR" ] && error "AgenticCommerce deployment failed"
[ -z "$ACW_ADDR" ] && error "AgenticCommerceWorker deployment failed"
success "AgenticCommerce:          $ACP_ADDR"
success "AgenticCommerceEvaluator: $ACE_ADDR"
success "AgenticCommerceWorker:    $ACW_ADDR  ← autonomous provider"
success "ReputationHook:           $HOOK_ADDR"
success "IdentityRegistry:         $IDENTITY_REGISTRY"
success "ReputationRegistry:       $REPUTATION_REGISTRY"
success "MockERC20 (tUSDC):        $MOCK_TOKEN_ADDR"

# =============================================================================
# 2. Register AgenticCommerceWorker as ERC-8004 agent (autonomous provider)
# =============================================================================
info "Registering AgenticCommerceWorker (autonomous provider) as ERC-8004 agent..."

# Deployer registers on behalf of the worker contract address
AGENT_ID_BEFORE=$(cast call "$IDENTITY_REGISTRY" "getLastId()(uint256)" --rpc-url "$RPC_URL")
cast send "$IDENTITY_REGISTRY" "register()" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
AGENT_ID=$(cast call "$IDENTITY_REGISTRY" "getLastId()(uint256)" --rpc-url "$RPC_URL")
AGENT_ID=$(( AGENT_ID - 1 ))

success "Worker ERC-8004 agentId: $AGENT_ID"

# Link worker contract → agentId in ReputationHook
cast send "$HOOK_ADDR" "registerAgent(address,uint256)" "$ACW_ADDR" "$AGENT_ID" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
success "Hook: worker contract linked to agentId $AGENT_ID"

# Mint tUSDC to deployer (client) — provider is a contract, doesn't need tokens
cast send "$MOCK_TOKEN_ADDR" "mint(address,uint256)" "$DEPLOYER" "10000000000" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet 2>/dev/null || true

# =============================================================================
# 3. Build and upload WAVS components
# =============================================================================
info "Building and uploading WAVS components..."

# ── Evaluator ────────────────────────────────────────────────────────────────
EVALUATOR_WASM="target/wasm32-wasip1/release/agentic_commerce_evaluator.wasm"
if [ ! -f "$EVALUATOR_WASM" ]; then
  info "Building evaluator WASM..."
  cargo component build -p agentic-commerce-evaluator --release --quiet
fi
EVALUATOR_DIGEST=$(curl -sf -X POST "$WAVS_URL/dev/components" \
  -H "Content-Type: application/wasm" \
  --data-binary "@$EVALUATOR_WASM" | python3 -c "import sys,json; print(json.load(sys.stdin)['digest'])")
success "Evaluator uploaded:  $EVALUATOR_DIGEST"

# ── Worker ───────────────────────────────────────────────────────────────────
WORKER_WASM="target/wasm32-wasip1/release/agentic_commerce_worker.wasm"
if [ ! -f "$WORKER_WASM" ]; then
  info "Building worker WASM..."
  cargo component build -p agentic-commerce-worker --release 2>&1 | grep -v "^warning"
fi
WORKER_DIGEST=$(curl -sf -X POST "$WAVS_URL/dev/components" \
  -H "Content-Type: application/wasm" \
  --data-binary "@$WORKER_WASM" | python3 -c "import sys,json; print(json.load(sys.stdin)['digest'])")
success "Worker uploaded:     $WORKER_DIGEST"

# ── Aggregator ───────────────────────────────────────────────────────────────
AGG_WASM="target/wasm32-wasip1/release/aggregator.wasm"
if [ ! -f "$AGG_WASM" ]; then
  cargo component build -p aggregator --release --quiet
fi
AGG_DIGEST=$(curl -sf -X POST "$WAVS_URL/dev/components" \
  -H "Content-Type: application/wasm" \
  --data-binary "@$AGG_WASM" | python3 -c "import sys,json; print(json.load(sys.stdin)['digest'])")
success "Aggregator uploaded: $AGG_DIGEST"

# =============================================================================
# 4. Register WAVS services — both use the same SM as the deployed contracts
# =============================================================================
# ACW is deployed with WORKER_SM_ADDR; ACE with EVALUATOR_SM_ADDR.
# Each WAVS service must register against the same SM its contract calls validate() on.

# register_service <label> <sm_addr> <manifest_json>
# Status → stderr; service_id → stdout.
register_service() {
  local label="$1"
  local sm="$2"
  local manifest="$3"

  local hash
  hash=$(echo "$manifest" | curl -sf -X POST "$WAVS_URL/dev/services" \
    -H "Content-Type: application/json" -d @- | python3 -c "import json,sys; print(json.load(sys.stdin)['hash'])")
  echo -e "${GREEN}[OK]${NC}    $label manifest: $hash" >&2

  local uri="http://127.0.0.1:8041/dev/services/$hash"
  cast send "$sm" "setServiceURI(string)" "$uri" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet

  local reg
  reg=$(curl -sf -X POST "$WAVS_URL/services" \
    -H "Content-Type: application/json" \
    -d "{\"service_manager\":{\"evm\":{\"chain\":\"$CHAIN_ID\",\"address\":\"$sm\"}}}")

  local sid
  sid=$(echo "$reg" | python3 -c "import json,sys; print(json.load(sys.stdin)['service_id'])" 2>/dev/null || true)
  if [ -z "$sid" ]; then
    sid=$(curl -sf "$WAVS_URL/services" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sm_l='$sm'.lower()
sids=d.get('service_ids',[])
svcs=d.get('services',[])
for i,svc in enumerate(svcs):
    if svc.get('manager',{}).get('evm',{}).get('address','').lower()==sm_l:
        print(sids[i]); break
else:
    print(sids[-1] if sids else '')
")
  fi
  echo -e "${GREEN}[OK]${NC}    $label service_id: $sid" >&2
  echo "$sid"
}

# fund_service <label> <sm_addr> <service_id>
# Derives signing key, funds it with ETH, sets operator weight in the SM.
fund_service() {
  local label="$1"
  local sm="$2"
  local sid="$3"

  local signer_resp
  signer_resp=$(curl -sf -X POST "$WAVS_URL/services/signer" \
    -H "Content-Type: application/json" \
    -d "{\"service_id\":\"$sid\",\"workflow_id\":\"default\",\"service_manager\":{\"evm\":{\"chain\":\"$CHAIN_ID\",\"address\":\"$sm\"}}}")

  local key hd
  key=$(echo "$signer_resp" | python3 -c "import json,sys; print(json.load(sys.stdin)['secp256k1']['evm_address'])")
  hd=$(echo "$signer_resp"  | python3 -c "import json,sys; print(json.load(sys.stdin)['secp256k1']['hd_index'])")
  success "$label signing key: $key (HD $hd)"

  cast send "$key" --value 1ether --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
  # Weight in the SM that this service's contract calls validate() on
  cast send "$sm" "setOperatorWeight(address,uint256)" "$key" 100 \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
}

# ── Worker service: watches JobFunded → submitWithResult via ACW ─────────────
info "Registering worker service (JobFunded → submitWithResult)..."
JOBFUNDED_HASH=$(cast keccak "JobFunded(uint256,uint256)")
WORKER_MANIFEST=$(python3 -c "
import json
print(json.dumps({
  'name': 'agentic-commerce-worker',
  'manager': {'evm': {'chain': '$CHAIN_ID', 'address': '$WORKER_SM_ADDR'}},
  'workflows': {
    'default': {
      'trigger': {
        'evm_contract_event': {
          'chain': '$CHAIN_ID',
          'address': '$ACP_ADDR',
          'event_hash': '$JOBFUNDED_HASH'
        }
      },
      'component': {
        'source': {'digest': '$WORKER_DIGEST'},
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
            'config': {'$CHAIN_ID': '$ACW_ADDR'}
          },
          'signature_kind': {'algorithm': 'secp256k1', 'prefix': 'eip191'}
        }
      }
    }
  },
  'status': 'active'
}))
")
WORKER_SERVICE_ID=$(register_service "Worker" "$WORKER_SM_ADDR" "$WORKER_MANIFEST")
sleep 2
fund_service "Worker" "$WORKER_SM_ADDR" "$WORKER_SERVICE_ID"

# ── Evaluator service: watches JobSubmitted → complete/reject via ACE ────────
info "Registering evaluator service (JobSubmitted → complete/reject)..."
JOBSUBMITTED_HASH=$(cast keccak "JobSubmitted(uint256,address,bytes32)")
EVALUATOR_MANIFEST=$(python3 -c "
import json
print(json.dumps({
  'name': 'agentic-commerce-evaluator',
  'manager': {'evm': {'chain': '$CHAIN_ID', 'address': '$EVALUATOR_SM_ADDR'}},
  'workflows': {
    'default': {
      'trigger': {
        'evm_contract_event': {
          'chain': '$CHAIN_ID',
          'address': '$ACP_ADDR',
          'event_hash': '$JOBSUBMITTED_HASH'
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
EVALUATOR_SERVICE_ID=$(register_service "Evaluator" "$EVALUATOR_SM_ADDR" "$EVALUATOR_MANIFEST")
sleep 2
fund_service "Evaluator" "$EVALUATOR_SM_ADDR" "$EVALUATOR_SERVICE_ID"

# Fund aggregator credential once
cast send "$AGG_CREDENTIAL" --value 1ether --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet

echo ""
echo -e "${BOLD}┌─────────────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│  WORKER    service_id: ${GREEN}${WORKER_SERVICE_ID}${NC}${BOLD}  │${NC}"
echo -e "${BOLD}│  EVALUATOR service_id: ${GREEN}${EVALUATOR_SERVICE_ID}${NC}${BOLD}  │${NC}"
echo -e "${BOLD}│  Worker  logs: ${CYAN}${WAVS_URL}/dev/logs/${WORKER_SERVICE_ID}${NC}${BOLD}  │${NC}"
echo -e "${BOLD}│  Evaluator logs: ${CYAN}${WAVS_URL}/dev/logs/${EVALUATOR_SERVICE_ID}${NC}${BOLD}  │${NC}"
echo -e "${BOLD}└─────────────────────────────────────────────────────────────────────┘${NC}"
echo ""

# =============================================================================
# 7. Demo: create job → fund → WAVS worker submits → WAVS evaluates (fully autonomous)
# =============================================================================
echo ""
echo -e "${BOLD}── Demo Flow ────────────────────────────────────────────────────${NC}"
echo ""
info "Demo URL: $DEMO_URL"
info "Provider: AgenticCommerceWorker (autonomous) = $ACW_ADDR"

BUDGET="100000000"  # 100 tUSDC (6 decimals)
NO_EXPIRY="0"

# Client approves AgenticCommerce to spend tUSDC
cast send "$MOCK_TOKEN_ADDR" "approve(address,uint256)" "$ACP_ADDR" "$BUDGET" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet

# Create job — provider is the AgenticCommerceWorker contract (autonomous)
cast send "$ACP_ADDR" \
  "createJob(address,address,uint64,string,address)(uint256)" \
  "$ACW_ADDR" "$ACE_ADDR" "$NO_EXPIRY" "$DEMO_URL" "$HOOK_ADDR" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet

JOB_ID=$(cast call "$ACP_ADDR" "getJobCount()(uint256)" --rpc-url "$RPC_URL")
success "Job created: jobId=$JOB_ID  provider=$ACW_ADDR (worker contract)"

# Set budget + fund → fires JobFunded → WAVS worker wakes up!
cast send "$ACP_ADDR" "setBudget(uint256,uint256)" "$JOB_ID" "$BUDGET" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
cast send "$ACP_ADDR" "fund(uint256,uint256)" "$JOB_ID" "$BUDGET" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --quiet
success "Job funded: $BUDGET tUSDC in escrow"
success "JobFunded event fired! → WAVS worker will fetch URL, hash body, and submit..."
echo ""
info "  The worker WASM will autonomously:"
info "    1. Decode JobFunded event"
info "    2. Fetch '$DEMO_URL'"
info "    3. Compute keccak256(response_body)"
info "    4. Call AgenticCommerceWorker.handleSignedEnvelope → submitWithResult()"
info "  Then the evaluator WASM will:"
info "    5. Decode JobSubmitted event"
info "    6. Re-fetch '$DEMO_URL', verify hash matches"
info "    7. Call AgenticCommerceEvaluator.handleSignedEnvelope → complete()"

# =============================================================================
# 8. Wait for both WAVS services to process
# =============================================================================
echo ""
info "Waiting ${WAIT_SECS}s for worker + evaluator to process..."
info "  Worker  logs: $WAVS_URL/dev/logs/$WORKER_SERVICE_ID"
info "  Evaluator logs: $WAVS_URL/dev/logs/$EVALUATOR_SERVICE_ID"
sleep "$WAIT_SECS"

# =============================================================================
# 9. Check result
# =============================================================================
echo ""
echo -e "${BOLD}── Results ─────────────────────────────────────────────────────${NC}"
echo ""

JOB_DATA=$(cast call "$ACP_ADDR" "getJob(uint256)((address,address,address,address,string,string,uint256,uint64,uint8))" \
  "$JOB_ID" --rpc-url "$RPC_URL")

# Status: 0=Open 1=Funded 2=Submitted 3=Completed 4=Rejected 5=Expired
STATUS=$(echo "$JOB_DATA" | python3 -c "
import sys, re
data = sys.stdin.read().strip().strip('()')
nums = re.findall(r'(?<![0-9a-fA-Fx\.\"])(\b\d+\b)(?!\s*\[)', data)
if nums: print(nums[-1])
else: print('?')
" 2>/dev/null || echo "?")

# Extract resultUri from job data (field 6, a string)
RESULT_URI=$(echo "$JOB_DATA" | python3 -c "
import sys, re
data = sys.stdin.read()
# Find all quoted strings
strings = re.findall(r'\"([^\"]*)\"', data)
# Second string is resultUri (first is description/URL)
print(strings[1] if len(strings) > 1 else '')
" 2>/dev/null || echo "")

# Worker contract balance (gets the payment)
WORKER_BALANCE=$(cast call "$MOCK_TOKEN_ADDR" "balanceOf(address)(uint256)" \
  "$ACW_ADDR" --rpc-url "$RPC_URL")

info "Job status: $STATUS (3=Completed, 4=Rejected)"
info "Worker contract balance: $WORKER_BALANCE tUSDC (raw)"
[ -n "$RESULT_URI" ] && info "Result URI: $RESULT_URI"

# ERC-8004 reputation
REP_COUNT=$(cast call "$REPUTATION_REGISTRY" \
  "getSummary(uint256,address[],string,string)(uint64,int128,uint8)" \
  "$AGENT_ID" "[]" "" "" --rpc-url "$RPC_URL" | awk 'NR==1{print $1}' 2>/dev/null || echo "?")

case "$STATUS" in
  3)
    echo ""
    echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${NC}"
    success "FULLY AUTONOMOUS LOOP COMPLETE! ⚡ ERC-8183 settlement"
    echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${NC}"
    echo ""
    info "  AgenticCommerce:          $ACP_ADDR"
    info "  AgenticCommerceWorker:    $ACW_ADDR  (autonomous provider)"
    info "  AgenticCommerceEvaluator: $ACE_ADDR"
    info "  Job ID:                   $JOB_ID"
    info "  Worker paid:              $BUDGET tUSDC (raw)"
    info "  ERC-8004 feedback count:  $REP_COUNT"
    [ -n "$RESULT_URI" ] && info "  Result URI:               $RESULT_URI"
    info "  Worker  logs: $WAVS_URL/dev/logs/$WORKER_SERVICE_ID"
    info "  Evaluator logs: $WAVS_URL/dev/logs/$EVALUATOR_SERVICE_ID"
    ;;
  4)
    warn "Job REJECTED — WAVS computed hash didn't match deliverable"
    warn "Worker logs: $WAVS_URL/dev/logs/$WORKER_SERVICE_ID"
    warn "Evaluator logs: $WAVS_URL/dev/logs/$EVALUATOR_SERVICE_ID"
    ;;
  2)
    warn "Job still Submitted — evaluator may still be processing (try longer WAIT_SECS)"
    warn "Evaluator logs: $WAVS_URL/dev/logs/$EVALUATOR_SERVICE_ID"
    ;;
  1)
    warn "Job still Funded — worker may still be processing (try longer WAIT_SECS)"
    warn "Worker logs: $WAVS_URL/dev/logs/$WORKER_SERVICE_ID"
    ;;
  *)
    warn "Unexpected job status: $STATUS"
    ;;
esac

echo ""
echo "Inspect job:"
echo "  cast call $ACP_ADDR 'getJob(uint256)((address,address,address,address,string,string,uint256,uint64,uint8))' $JOB_ID --rpc-url $RPC_URL"
echo ""
echo "ERC-8004 reputation:"
echo "  cast call $REPUTATION_REGISTRY 'getSummary(uint256,address[],string,string)' $AGENT_ID '[]' '' '' --rpc-url $RPC_URL"
echo ""
