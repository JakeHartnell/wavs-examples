use crate::bindings::world::{
    host,
    wavs::{
        operator::{input as component_input, output as component_output},
        types::{
            events::{TriggerDataAtprotoEvent, TriggerDataEvmContractEvent, TriggerDataHypercoreAppend},
            service::ServiceManager,
        },
    },
};
use alloy_sol_types::SolValue;
use anyhow::Result;
use wavs_wasi_utils::decode_event_log_data;

/// Decode an incoming trigger into `(trigger_id, payload_bytes)`.
///
/// Handles:
/// - EVM contract events (the primary production path)
/// - Raw bytes (used for local CLI / `wasi-exec` testing)
/// - ATProto events
/// - Hypercore appends
pub fn decode_trigger_event(
    trigger_data: component_input::TriggerData,
) -> Result<(u64, Vec<u8>)> {
    match trigger_data {
        component_input::TriggerData::EvmContractEvent(TriggerDataEvmContractEvent {
            log, ..
        }) => {
            let event: solidity::NewTrigger = decode_event_log_data!(log.data)?;
            let trigger_info = solidity::TriggerInfo::abi_decode(&event.triggerData)?;
            Ok((trigger_info.triggerId, trigger_info.data.to_vec()))
        }
        component_input::TriggerData::Raw(bytes) => Ok((0, bytes)),
        component_input::TriggerData::AtprotoEvent(TriggerDataAtprotoEvent {
            record_data,
            sequence,
            ..
        }) => Ok((
            sequence.try_into().expect("sequence must fit in u64"),
            record_data
                .expect("record_data was not provided")
                .into_bytes(),
        )),
        component_input::TriggerData::HypercoreAppend(TriggerDataHypercoreAppend {
            index,
            data,
            ..
        }) => Ok((index, data)),
        _ => Err(anyhow::anyhow!("Unsupported trigger data type")),
    }
}

/// Encode component output for on-chain submission.
///
/// Routes to EVM or Cosmos encoding based on the service manager type.
pub fn encode_trigger_output(
    trigger_id: u64,
    output: impl AsRef<[u8]>,
    service_manager: ServiceManager,
) -> component_output::WasmResponse {
    match service_manager {
        ServiceManager::Evm(_) => evm_encode_trigger_output(trigger_id, output),
        ServiceManager::Cosmos(_) => {
            // Cosmos encoding: wrap in a simple length-prefixed message
            // For EVM-only examples this path is unused, but keeping it non-panicking.
            component_output::WasmResponse {
                payload: cosmos_encode_payload(trigger_id, output.as_ref()),
                ordering: None,
                event_id_salt: None,
            }
        }
    }
}

fn evm_encode_trigger_output(
    trigger_id: u64,
    output: impl AsRef<[u8]>,
) -> component_output::WasmResponse {
    component_output::WasmResponse {
        payload: solidity::DataWithId {
            triggerId: trigger_id,
            data: output.as_ref().to_vec().into(),
        }
        .abi_encode(),
        ordering: None,
        event_id_salt: None,
    }
}

fn cosmos_encode_payload(trigger_id: u64, output: &[u8]) -> Vec<u8> {
    // Simple encoding: 8-byte little-endian trigger_id || payload
    let mut buf = Vec::with_capacity(8 + output.len());
    buf.extend_from_slice(&trigger_id.to_le_bytes());
    buf.extend_from_slice(output);
    buf
}

/// Solidity ABI types used in trigger decode/encode.
mod solidity {
    use alloy_sol_macro::sol;
    pub use ISimpleTrigger::TriggerInfo;
    pub use SimpleTrigger::NewTrigger;

    sol!(
        #[allow(missing_docs)]
        #[sol(rpc)]
        SimpleTrigger,
        "../../../out/SimpleTrigger.sol/SimpleTrigger.json"
    );

    sol!(
        #[allow(missing_docs)]
        ISimpleSubmit,
        "../../../out/SimpleSubmit.sol/SimpleSubmit.json"
    );

    pub use ISimpleSubmit::DataWithId;
}
