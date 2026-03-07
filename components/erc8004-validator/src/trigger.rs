use crate::bindings::wavs::types::events::{TriggerData, TriggerDataEvmContractEvent};
use crate::bindings::WasmResponse;
use alloy_primitives::{Bytes, FixedBytes, LogData};
use alloy_sol_types::{SolEvent, SolValue};
use anyhow::Result;

/// Where the trigger output should be sent
pub enum Destination {
    Ethereum,
    CliOutput,
}

/// Data extracted from a ValidationRequested trigger event
pub struct ValidationTriggerData {
    pub trigger_id: u64,
    pub request_uri: String,
    pub request_hash: FixedBytes<32>,
    pub dest: Destination,
}

/// Decode a ValidationTrigger NewTrigger event into its component parts.
///
/// The TriggerInfo.data field is ABI-encoded (string requestURI, bytes32 requestHash).
pub fn decode_trigger_event(trigger_data: TriggerData) -> Result<ValidationTriggerData> {
    match trigger_data {
        TriggerData::EvmContractEvent(TriggerDataEvmContractEvent { log, .. }) => {
            let event: solidity::NewTrigger = decode_log(&log.data.topics, log.data.data)?;
            let trigger_info =
                <solidity::TriggerInfo as SolValue>::abi_decode(&event._triggerInfo)?;

            let (request_uri, request_hash) =
                <(String, FixedBytes<32>) as SolValue>::abi_decode(&trigger_info.data)?;

            Ok(ValidationTriggerData {
                trigger_id: trigger_info.triggerId,
                request_uri,
                request_hash,
                dest: Destination::Ethereum,
            })
        }
        TriggerData::Raw(data) => {
            // For CLI testing: data = ABI-encoded (string uri, bytes32 hash)
            // Or just a plain URI string for quick manual tests
            let (request_uri, request_hash) = if data.starts_with(b"0x") {
                let hex_str = std::str::from_utf8(&data).unwrap_or("");
                let decoded = hex::decode(&hex_str[2..])
                    .map_err(|e| anyhow::anyhow!("hex decode: {}", e))?;
                <(String, FixedBytes<32>) as SolValue>::abi_decode(&decoded)?
            } else {
                // Plain URI + zero hash (useful for quick tests without a real hash)
                let uri = String::from_utf8(data.clone())
                    .map_err(|e| anyhow::anyhow!("UTF-8: {}", e))?;
                (uri, FixedBytes::<32>::default())
            };

            Ok(ValidationTriggerData {
                trigger_id: 0,
                request_uri,
                request_hash,
                dest: Destination::CliOutput,
            })
        }
        _ => Err(anyhow::anyhow!("Unsupported trigger data type")),
    }
}

/// Encode the validation result into a WasmResponse for submission.
///
/// `data` is ABI-encoded (bytes32 requestHash, uint8 response, string tag),
/// matching what ValidationSubmit.sol expects to decode.
pub fn encode_validation_output(
    trigger_id: u64,
    request_hash: FixedBytes<32>,
    response: u8,
    tag: &str,
) -> WasmResponse {
    let result = solidity::ValidationResult {
        requestHash: request_hash,
        response,
        tag: tag.to_string(),
    };
    WasmResponse {
        payload: solidity::DataWithId {
            triggerId: trigger_id,
            data: result.abi_encode().into(),
        }
        .abi_encode(),
        ordering: None,
        event_id_salt: None,
    }
}

/// Inline log decoder — avoids wstd/wavs-wasi-utils (which pull in WASI @0.2.9).
fn decode_log<T: SolEvent>(topics: &[Vec<u8>], data: Vec<u8>) -> Result<T> {
    let topics: Vec<FixedBytes<32>> =
        topics.iter().map(|t| FixedBytes::<32>::from_slice(t)).collect();
    let log_data =
        LogData::new(topics, Bytes::from(data)).ok_or_else(|| anyhow::anyhow!("log data"))?;
    T::decode_log_data(&log_data).map_err(|e| anyhow::anyhow!("decode: {}", e))
}

pub mod solidity {
    use alloy_sol_macro::sol;
    pub use ITypes::*;

    sol!("../../src/interfaces/ITypes.sol");

    sol! {
        /// Matches the ABI shape of (bytes32 requestHash, uint8 response, string tag)
        /// that ValidationSubmit.sol decodes from the DataWithId.data field.
        struct ValidationResult {
            bytes32 requestHash;
            uint8 response;
            string tag;
        }
    }
}
