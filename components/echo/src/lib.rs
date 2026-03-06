#[rustfmt::skip]
pub mod bindings;
mod trigger;

use crate::bindings::{export, Guest, TriggerAction, WasmResponse};
use alloy_sol_types::SolValue;
use anyhow::Result;
use trigger::{decode_trigger_event, encode_trigger_output, Destination};
use wavs_wasi_utils::evm::alloy_primitives::hex;

struct Component;
export!(Component with_types_in bindings);

impl Guest for Component {
    fn run(action: TriggerAction) -> Result<Option<WasmResponse>, String> {
        let (trigger_id, req, dest) =
            decode_trigger_event(action.data).map_err(|e| e.to_string())?;

        // Decode the input: handle both hex-encoded (CLI) and raw ABI-encoded (production)
        let input_str = decode_string_input(&req).map_err(|e| e.to_string())?;

        println!("Echo component received: {}", input_str);

        // Echo it straight back
        let output = serde_json::json!({
            "echo": input_str
        });
        let output_bytes = serde_json::to_vec(&output).map_err(|e| e.to_string())?;

        let response = match dest {
            Destination::Ethereum => Some(encode_trigger_output(trigger_id, &output_bytes)),
            Destination::CliOutput => Some(WasmResponse {
                payload: output_bytes.into(),
                ordering: None,
                event_id_salt: None,
            }),
        };

        Ok(response)
    }
}

/// Decode a string input from trigger data.
/// Handles two cases:
/// - Raw CLI testing: UTF-8 string passed directly
/// - Production/ABI: hex-prefixed or raw ABI-encoded string
fn decode_string_input(req: &[u8]) -> Result<String> {
    // Try plain UTF-8 first (Raw trigger from CLI)
    if let Ok(s) = std::str::from_utf8(req) {
        // If it's a hex string, ABI-decode it
        if s.starts_with("0x") {
            let bytes = hex::decode(&s[2..])?;
            return Ok(<String as SolValue>::abi_decode(&bytes)?);
        }
        // Plain string — return as-is
        return Ok(s.to_string());
    }
    // Binary ABI-encoded string
    Ok(<String as SolValue>::abi_decode(req)?)
}
