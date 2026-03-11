use crate::bindings::wavs::types::events::{TriggerData, TriggerDataEvmContractEvent};
use crate::bindings::WasmResponse;
use alloy_primitives::{Bytes, FixedBytes, LogData, U256};
use alloy_sol_types::{sol, SolCall, SolEvent, SolValue};
use anyhow::{anyhow, Result};

// ═══════════════════════════════════════════════════════════════════════════
// ABI definitions
// ═══════════════════════════════════════════════════════════════════════════

sol! {
    /// ERC-8183 AgenticCommerce.sol events
    event JobSubmitted(
        uint256 indexed jobId,
        address indexed provider,
        bytes32 deliverable
    );

    /// Standard EvaluationResult — compatible with existing AgenticCommerceEvaluator.sol.
    /// Score and reasoning are preserved in WAVS logs as the verifiable attestation record.
    struct EvaluationResult {
        uint256 jobId;
        bool    isComplete;
        bytes32 attestation;  // keccak256(reasoning) — on-chain proof of LLM verdict
    }

    /// AgenticCommerce.getJobDescription(jobId) — the task prompt
    function getJobDescription(uint256 jobId) external view returns (string memory description);

    /// AgenticCommerce.getJobResultUri(jobId) — where the worker published their output
    function getJobResultUri(uint256 jobId) external view returns (string memory resultUri);
}

// ═══════════════════════════════════════════════════════════════════════════
// Trigger data
// ═══════════════════════════════════════════════════════════════════════════

pub struct JobSubmittedEvent {
    pub job_id:          U256,
    pub provider:        alloy_primitives::Address,
    pub deliverable:     [u8; 32],
    pub result_uri:      String,  // where the worker published their output
    pub job_description: String,  // original task prompt (for LLM quality evaluation)
}

/// Decode a JobSubmitted event, fetch the job description via eth_call.
pub fn decode_trigger_event(trigger_data: TriggerData) -> Result<JobSubmittedEvent> {
    match trigger_data {
        TriggerData::EvmContractEvent(TriggerDataEvmContractEvent { chain, log }) => {
            let event: JobSubmitted = decode_log(&log.data.topics, log.data.data.clone())?;

            let job_id      = event.jobId;
            let provider    = event.provider;
            let deliverable: [u8; 32] = event.deliverable.into();
            let acp_address = alloy_primitives::Address::from_slice(&log.address.raw_bytes);

            // Fetch task prompt and result URI via eth_call
            let job_description = fetch_job_description(&chain, acp_address, job_id)?;
            let result_uri      = fetch_job_result_uri(&chain, acp_address, job_id)?;

            Ok(JobSubmittedEvent { job_id, provider, deliverable, result_uri, job_description })
        }

        TriggerData::Raw(data) => {
            let v: serde_json::Value = serde_json::from_slice(&data)
                .map_err(|e| anyhow!("raw JSON parse: {}", e))?;

            let job_id = U256::from(v["jobId"].as_u64().unwrap_or(0));
            let provider = v["provider"]
                .as_str()
                .unwrap_or("0x0000000000000000000000000000000000000000")
                .parse::<alloy_primitives::Address>()
                .map_err(|e| anyhow!("provider addr: {}", e))?;

            let deliverable_hex = v["deliverable"].as_str().unwrap_or("0x");
            let deliverable_bytes = hex::decode(deliverable_hex.trim_start_matches("0x"))
                .map_err(|e| anyhow!("deliverable hex: {}", e))?;
            let mut deliverable = [0u8; 32];
            let len = deliverable_bytes.len().min(32);
            deliverable[..len].copy_from_slice(&deliverable_bytes[..len]);

            let result_uri = v["resultUri"].as_str().unwrap_or("").to_string();
            let job_description = v["jobDescription"]
                .as_str()
                .unwrap_or("")
                .to_string();

            Ok(JobSubmittedEvent { job_id, provider, deliverable, result_uri, job_description })
        }

        _ => Err(anyhow!("Unsupported trigger data type")),
    }
}

/// Encode the LLM evaluation verdict as a WasmResponse payload.
/// Uses the same EvaluationResult ABI as the keccak evaluator — no new contract needed.
/// keccak256(reasoning) is stored as `attestation` so the reasoning is verifiable off-chain
/// via WAVS logs while keeping the on-chain footprint minimal.
pub fn encode_evaluation(
    job_id: U256,
    is_complete: bool,
    _score: u8,
    reasoning: String,
) -> WasmResponse {
    let attestation: [u8; 32] = *alloy_primitives::keccak256(reasoning.as_bytes());

    let payload = EvaluationResult {
        jobId:       job_id,
        isComplete:  is_complete,
        attestation: FixedBytes::<32>::from(attestation),
    }
    .abi_encode();

    WasmResponse { payload, ordering: None, event_id_salt: None }
}

// ═══════════════════════════════════════════════════════════════════════════
// eth_call: read job.description from AgenticCommerce
// ═══════════════════════════════════════════════════════════════════════════

fn fetch_job_result_uri(
    chain_key: &str,
    acp_address: alloy_primitives::Address,
    job_id: U256,
) -> Result<String> {
    let call_data = getJobResultUriCall { jobId: job_id }.abi_encode();
    eth_call_string(chain_key, acp_address, &call_data)
}

fn fetch_job_description(
    chain_key: &str,
    acp_address: alloy_primitives::Address,
    job_id: U256,
) -> Result<String> {
    let call_data = getJobDescriptionCall { jobId: job_id }.abi_encode();
    eth_call_string(chain_key, acp_address, &call_data)
}

/// Generic eth_call that returns an ABI-encoded string result.
fn eth_call_string(
    chain_key: &str,
    acp_address: alloy_primitives::Address,
    call_data: &[u8],
) -> Result<String> {
    use crate::bindings::host;

    let chain_cfg = host::get_evm_chain_config(chain_key)
        .ok_or_else(|| anyhow!("No chain config for '{}'", chain_key))?;
    let rpc_url = chain_cfg
        .http_endpoint
        .ok_or_else(|| anyhow!("No http_endpoint for chain '{}'", chain_key))?;

    let call_hex  = format!("0x{}", hex::encode(call_data));
    let to_hex    = format!("{:?}", acp_address);

    let jrpc = serde_json::json!({
        "jsonrpc": "2.0",
        "method":  "eth_call",
        "params":  [{"to": to_hex, "data": call_hex}, "latest"],
        "id":      1
    });
    let jrpc_bytes = serde_json::to_vec(&jrpc)
        .map_err(|e| anyhow!("json serialize: {}", e))?;

    let response_bytes = crate::http::post_json(&rpc_url, &jrpc_bytes)
        .map_err(|e| anyhow!("eth_call POST: {}", e))?;

    let response: serde_json::Value = serde_json::from_slice(&response_bytes)
        .map_err(|e| anyhow!("json parse: {}", e))?;

    if let Some(err) = response.get("error") {
        return Err(anyhow!("eth_call error: {}", err));
    }

    let result_hex = response["result"]
        .as_str()
        .ok_or_else(|| anyhow!("eth_call: no result field"))?;

    let result_bytes = hex::decode(result_hex.trim_start_matches("0x"))
        .map_err(|e| anyhow!("result hex decode: {}", e))?;

    if result_bytes.len() < 64 {
        return Err(anyhow!("eth_call result too short ({} bytes)", result_bytes.len()));
    }
    let len = u64::from_be_bytes(
        result_bytes[56..64].try_into().map_err(|_| anyhow!("length slice error"))?,
    ) as usize;

    if result_bytes.len() < 64 + len {
        return Err(anyhow!(
            "eth_call result too short for string: need {} got {}",
            64 + len,
            result_bytes.len()
        ));
    }

    String::from_utf8(result_bytes[64..64 + len].to_vec())
        .map_err(|e| anyhow!("string UTF-8 decode: {}", e))
}

// ═══════════════════════════════════════════════════════════════════════════
// Log decoder
// ═══════════════════════════════════════════════════════════════════════════

fn decode_log<T: SolEvent>(topics: &[Vec<u8>], data: Vec<u8>) -> Result<T> {
    let topics: Vec<FixedBytes<32>> = topics
        .iter()
        .map(|t| FixedBytes::<32>::from_slice(t))
        .collect();
    let log_data =
        LogData::new(topics, Bytes::from(data)).ok_or_else(|| anyhow!("invalid log data"))?;
    T::decode_log_data(&log_data).map_err(|e| anyhow!("log decode: {}", e))
}

use hex;
