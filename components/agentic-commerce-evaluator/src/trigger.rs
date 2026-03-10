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

    /// AgenticCommerce.getJob return value
    struct Job {
        address client;
        address provider;
        address evaluator;
        address hook;
        string  description;
        uint256 budget;
        uint64  expiredAt;
        uint8   status;  // JobStatus enum
    }

    /// AgenticCommerceEvaluator payload
    struct EvaluationResult {
        uint256 jobId;
        bool    isComplete;
        bytes32 attestation;
    }

    /// AgenticCommerce.getJob(jobId) view function
    function getJob(uint256 jobId) external view returns (
        address client,
        address provider,
        address evaluator,
        address hook,
        string  description,
        uint256 budget,
        uint64  expiredAt,
        uint8   status
    );
}

// ═══════════════════════════════════════════════════════════════════════════
// Trigger data
// ═══════════════════════════════════════════════════════════════════════════

pub struct JobSubmittedEvent {
    pub job_id:      U256,
    pub provider:    alloy_primitives::Address,
    pub deliverable: [u8; 32],
    pub url:         String,
    /// The chain key from the trigger (e.g. "evm:31337")
    pub chain:       String,
    /// The AgenticCommerce contract address (from the log)
    pub acp_address: alloy_primitives::Address,
}

/// Decode a JobSubmitted event from an EvmContractEvent trigger.
///
/// Then reads job.description (the URL) via JSON-RPC eth_call.
pub fn decode_trigger_event(trigger_data: TriggerData) -> Result<JobSubmittedEvent> {
    match trigger_data {
        TriggerData::EvmContractEvent(TriggerDataEvmContractEvent { chain, log }) => {
            // Decode the JobSubmitted event
            let event: JobSubmitted = decode_log(&log.data.topics, log.data.data.clone())?;

            let job_id = event.jobId;
            let provider = event.provider;
            let deliverable: [u8; 32] = event.deliverable.into();

            // Parse contract address from log
            let acp_address = alloy_primitives::Address::from_slice(&log.address.raw_bytes);

            // Fetch job description (URL) via eth_call to getJob(jobId)
            let url = fetch_job_description(&chain, acp_address, job_id)?;

            Ok(JobSubmittedEvent { job_id, provider, deliverable, url, chain, acp_address })
        }

        TriggerData::Raw(data) => {
            // CLI testing: pass JSON { "jobId": 1, "provider": "0x...", "deliverable": "0x...", "url": "https://..." }
            let v: serde_json::Value = serde_json::from_slice(&data)
                .map_err(|e| anyhow!("raw JSON parse: {}", e))?;

            let job_id = U256::from(v["jobId"].as_u64().unwrap_or(0));
            let provider = v["provider"].as_str().unwrap_or("0x0000000000000000000000000000000000000000")
                .parse::<alloy_primitives::Address>()
                .map_err(|e| anyhow!("provider addr: {}", e))?;
            let deliverable_hex = v["deliverable"].as_str().unwrap_or("0x");
            let deliverable_bytes = hex::decode(deliverable_hex.trim_start_matches("0x"))
                .map_err(|e| anyhow!("deliverable hex: {}", e))?;
            let mut deliverable = [0u8; 32];
            let len = deliverable_bytes.len().min(32);
            deliverable[..len].copy_from_slice(&deliverable_bytes[..len]);
            let url = v["url"].as_str().unwrap_or("").to_string();

            Ok(JobSubmittedEvent {
                job_id,
                provider,
                deliverable,
                url,
                chain: "evm:31337".to_string(),
                acp_address: alloy_primitives::Address::ZERO,
            })
        }

        _ => Err(anyhow!("Unsupported trigger data type")),
    }
}

/// Encode the evaluation verdict as a WasmResponse payload.
///
/// The AgenticCommerceEvaluator.handleSignedEnvelope decodes this as:
///   (uint256 jobId, bool isComplete, bytes32 attestation)
pub fn encode_evaluation(job_id: U256, is_complete: bool, attestation: [u8; 32]) -> WasmResponse {
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

/// Call AgenticCommerce.getJob(jobId) via JSON-RPC eth_call and return job.description.
fn fetch_job_description(
    chain_key: &str,
    acp_address: alloy_primitives::Address,
    job_id: U256,
) -> Result<String> {
    use crate::bindings::host;

    // Get the RPC HTTP endpoint for this chain
    let chain_cfg = host::get_evm_chain_config(chain_key)
        .ok_or_else(|| anyhow!("No chain config for '{}'", chain_key))?;
    let rpc_url = chain_cfg
        .http_endpoint
        .ok_or_else(|| anyhow!("No http_endpoint for chain '{}'", chain_key))?;

    // Encode eth_call: getJob(jobId)
    let call_data = getJobCall { jobId: job_id }.abi_encode();
    let call_hex = format!("0x{}", hex::encode(&call_data));
    let to_hex = format!("{:?}", acp_address);

    let jrpc = serde_json::json!({
        "jsonrpc": "2.0",
        "method": "eth_call",
        "params": [{"to": to_hex, "data": call_hex}, "latest"],
        "id": 1
    });
    let jrpc_bytes = serde_json::to_vec(&jrpc)
        .map_err(|e| anyhow!("json serialize: {}", e))?;

    // POST via raw WASI HTTP
    let response_bytes = crate::http::post(&rpc_url, &jrpc_bytes)
        .map_err(|e| anyhow!("eth_call POST: {}", e))?;

    // Parse JSON-RPC response
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

    // ABI decode the Job tuple return
    let decoded = getJobCall::abi_decode_returns(&result_bytes)
        .map_err(|e| anyhow!("getJob decode: {}", e))?;

    Ok(decoded.description)
}

// ═══════════════════════════════════════════════════════════════════════════
// Log decoder (same pattern as erc8004-validator, no wstd)
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
use serde_json;
