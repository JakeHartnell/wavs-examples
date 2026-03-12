use crate::bindings::wavs::types::events::{TriggerData, TriggerDataEvmContractEvent};
use crate::bindings::WasmResponse;
use alloy_primitives::{Bytes, FixedBytes, LogData, U256};
use alloy_sol_types::{sol, SolCall, SolEvent, SolValue};
use anyhow::{anyhow, Result};

// ═══════════════════════════════════════════════════════════════════════════
// ABI definitions
// ═══════════════════════════════════════════════════════════════════════════

sol! {
    /// ERC-8183 AgenticCommerce.sol — JobFunded is the worker trigger
    event JobFunded(
        uint256 indexed jobId,
        uint256 budget
    );

    /// AgenticCommerce.getJobDescription(jobId)
    function getJobDescription(uint256 jobId) external view returns (string memory description);

    /// Worker result payload — decoded by AgenticCommerceWorker.sol
    /// Fixed-size only: avoids ABI edge cases with dynamic types across WASM/EVM.
    /// resultUri is stored separately (paste.rs) and logged but not passed on-chain.
    struct WorkerResult {
        uint256 jobId;
        bytes32 deliverable;  // keccak256(work_output)
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Trigger data
// ═══════════════════════════════════════════════════════════════════════════

pub struct JobFundedEvent {
    pub job_id:      U256,
    pub budget:      U256,
    pub client:      alloy_primitives::Address,  // from log.address context
    pub description: String,
}

/// Decode a JobFunded event and fetch the job description via eth_call.
pub fn decode_trigger_event(trigger_data: TriggerData) -> Result<JobFundedEvent> {
    match trigger_data {
        TriggerData::EvmContractEvent(TriggerDataEvmContractEvent { chain, log }) => {
            let event: JobFunded = decode_log(&log.data.topics, log.data.data.clone())?;

            let job_id  = event.jobId;
            let budget  = event.budget;
            let acp_address = alloy_primitives::Address::from_slice(&log.address.raw_bytes);

            // Fetch job description (task prompt) via eth_call
            let description = fetch_job_description(&chain, acp_address, job_id)?;

            Ok(JobFundedEvent {
                job_id,
                budget,
                client: acp_address, // acp contract address as placeholder; real client in job struct
                description,
            })
        }

        TriggerData::Raw(data) => {
            let v: serde_json::Value = serde_json::from_slice(&data)
                .map_err(|e| anyhow!("raw JSON parse: {}", e))?;

            let job_id = U256::from(v["jobId"].as_u64().unwrap_or(0));
            let budget = U256::from(v["budget"].as_u64().unwrap_or(0));
            let description = v["description"].as_str().unwrap_or("").to_string();

            Ok(JobFundedEvent {
                job_id,
                budget,
                client: alloy_primitives::Address::ZERO,
                description,
            })
        }

        _ => Err(anyhow!("Unsupported trigger data type")),
    }
}

/// Encode the worker result for AgenticCommerceWorker.handleSignedEnvelope.
/// Fixed-size payload: (uint256 jobId, bytes32 deliverable).
/// resultUri is returned separately for logging but not ABI-encoded.
pub fn encode_worker_result(job_id: U256, deliverable: [u8; 32], _result_uri: String) -> WasmResponse {
    let payload = WorkerResult {
        jobId:       job_id,
        deliverable: FixedBytes::<32>::from(deliverable),
    }
    .abi_encode();

    WasmResponse { payload, ordering: None, event_id_salt: None }
}

// ═══════════════════════════════════════════════════════════════════════════
// eth_call: read job.description from AgenticCommerce
// ═══════════════════════════════════════════════════════════════════════════

fn fetch_job_description(
    chain_key: &str,
    acp_address: alloy_primitives::Address,
    job_id: U256,
) -> Result<String> {
    use crate::bindings::host;

    let chain_cfg = host::get_evm_chain_config(chain_key)
        .ok_or_else(|| anyhow!("No chain config for '{}'", chain_key))?;
    let rpc_url = chain_cfg
        .http_endpoint
        .ok_or_else(|| anyhow!("No http_endpoint for chain '{}'", chain_key))?;

    let call_data = getJobDescriptionCall { jobId: job_id }.abi_encode();
    let call_hex  = format!("0x{}", hex::encode(&call_data));
    let to_hex    = format!("{:?}", acp_address);

    let jrpc = serde_json::json!({
        "jsonrpc": "2.0",
        "method":  "eth_call",
        "params":  [{"to": to_hex, "data": call_hex}, "latest"],
        "id":      1
    });

    let response_bytes = crate::http::post_json(&rpc_url, &serde_json::to_vec(&jrpc)
        .map_err(|e| anyhow!("json serialize: {}", e))?)
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
            64 + len, result_bytes.len()
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
