use crate::bindings::wavs::types::events::{TriggerData, TriggerDataEvmContractEvent};
use crate::bindings::WasmResponse;
use alloy_primitives::{Bytes, FixedBytes};
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
    pub dest: Destination,
}

/// Decode a ValidationTrigger NewTrigger event.
///
/// TriggerInfo.data = bytes(requestURI) — raw UTF-8 bytes of the URI, same
/// pattern as WavsTrigger. The requestHash lives in the contract; the submit
/// contract does the on-chain comparison.
pub fn decode_trigger_event(trigger_data: TriggerData) -> Result<ValidationTriggerData> {
    match trigger_data {
        TriggerData::EvmContractEvent(TriggerDataEvmContractEvent { log, .. }) => {
            let event: solidity::NewTrigger = decode_log(&log.data.topics, log.data.data)?;
            let trigger_info =
                <solidity::TriggerInfo as SolValue>::abi_decode(&event._triggerInfo)?;

            // data = raw UTF-8 bytes of the URI
            let request_uri = String::from_utf8(trigger_info.data.to_vec())
                .map_err(|e| anyhow::anyhow!("URI is not valid UTF-8: {}", e))?;

            Ok(ValidationTriggerData {
                trigger_id: trigger_info.triggerId,
                request_uri,
                dest: Destination::Ethereum,
            })
        }
        TriggerData::Raw(data) => {
            // CLI testing: pass the URI directly as raw bytes (or hex-prefixed ABI string)
            let request_uri = if data.starts_with(b"0x") {
                let hex_str = std::str::from_utf8(&data).unwrap_or("");
                let decoded = hex::decode(&hex_str[2..])
                    .map_err(|e| anyhow::anyhow!("hex decode: {}", e))?;
                <String as SolValue>::abi_decode(&decoded)
                    .unwrap_or_else(|_| String::from_utf8_lossy(&decoded).into_owned())
            } else {
                String::from_utf8(data.clone())
                    .map_err(|e| anyhow::anyhow!("UTF-8: {}", e))?
            };

            Ok(ValidationTriggerData {
                trigger_id: 0,
                request_uri,
                dest: Destination::CliOutput,
            })
        }
        _ => Err(anyhow::anyhow!("Unsupported trigger data type")),
    }
}

/// Encode the computed hash as the WasmResponse payload.
///
/// The submit contract (ValidationSubmit.sol) decodes this as `bytes32` and
/// compares against the stored requestHash to produce the pass/fail verdict.
pub fn encode_validation_output(trigger_id: u64, computed_hash: FixedBytes<32>) -> WasmResponse {
    WasmResponse {
        payload: solidity::DataWithId {
            triggerId: trigger_id,
            data: computed_hash.abi_encode().into(),
        }
        .abi_encode(),
        ordering: None,
        event_id_salt: None,
    }
}

/// Inline log decoder — avoids pulling in wstd/wavs-wasi-utils (@0.2.9).
fn decode_log<T: SolEvent>(topics: &[Vec<u8>], data: Vec<u8>) -> Result<T> {
    let topics: Vec<FixedBytes<32>> =
        topics.iter().map(|t| FixedBytes::<32>::from_slice(t)).collect();
    let log_data =
        LogData::new(topics, Bytes::from(data)).ok_or_else(|| anyhow::anyhow!("log data"))?;
    T::decode_log_data(&log_data).map_err(|e| anyhow::anyhow!("decode: {}", e))
}

use alloy_primitives::LogData;

pub mod solidity {
    use alloy_sol_macro::sol;
    pub use ITypes::*;

    sol!("../../src/interfaces/ITypes.sol");
}
