#[rustfmt::skip]
pub mod bindings;
mod trigger;

use crate::bindings::wavs::types::core::LogLevel;
use crate::bindings::wasi::keyvalue::store;
use crate::bindings::{export, host, Guest, TriggerAction, WasmResponse};
use trigger::{decode_trigger_event, encode_trigger_output, Destination};

struct Component;
export!(Component with_types_in bindings);

impl Guest for Component {
    fn run(action: TriggerAction) -> Result<Vec<WasmResponse>, String> {
        let (trigger_id, data, dest) =
            decode_trigger_event(action.data).map_err(|e| e.to_string())?;

        let msg = String::from_utf8_lossy(&data).to_string();
        let byte_count = data.len();

        host::log(LogLevel::Info, &format!("chain-responder: received {} bytes: {}", byte_count, msg));

        // Store raw bytes in KV store: bucket="chain", key="output"
        let bucket = store::open("chain").map_err(|e| format!("open bucket: {:?}", e))?;
        bucket.set("output", &data).map_err(|e| format!("kv set: {:?}", e))?;

        let output = serde_json::json!({
            "stored": msg,
            "byte_count": byte_count
        });
        let output_bytes = serde_json::to_vec(&output).map_err(|e| e.to_string())?;

        let response = match dest {
            Destination::Ethereum => encode_trigger_output(trigger_id, &output_bytes),
            Destination::CliOutput => {
                WasmResponse { payload: output_bytes.into(), ordering: None, event_id_salt: None }
            }
        };

        Ok(vec![response])
    }
}
