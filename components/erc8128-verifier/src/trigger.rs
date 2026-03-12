use crate::bindings::wavs::types::events::TriggerData;
use anyhow::Result;
use serde::Deserialize;
use std::collections::HashMap;

/// Input payload for the ERC-8128 verifier.
///
/// Passed as JSON in the raw trigger bytes. The caller should populate this
/// from the actual HTTP request headers and derived component values.
///
/// # Example JSON
/// ```json
/// {
///   "signature_input": "eth=(\"@method\" \"@authority\" \"@path\");keyid=\"eip8128:1:0x...\";created=1618884475;expires=1618884775;nonce=\"abc123\"",
///   "signature": "eth=:base64bytes:",
///   "label": "eth",
///   "components": {
///     "@method": "POST",
///     "@authority": "api.example.com",
///     "@path": "/orders"
///   }
/// }
/// ```
///
/// Derived component values must be pre-canonicalized by the caller per RFC 9421:
/// - `@method` → uppercase HTTP method string (e.g. "POST")
/// - `@authority` → `host` header value (lowercase, with port if non-default)
/// - `@path` → absolute path (e.g. "/orders")
/// - `@query` → query string including "?" (e.g. "?status=pending")
/// - `content-digest` → full header field value (e.g. "sha-256=:AbCd==:")
#[derive(Deserialize)]
pub struct Erc8128Input {
    /// Value of the `Signature-Input` header
    pub signature_input: String,
    /// Value of the `Signature` header
    pub signature: String,
    /// Signature label to verify (defaults to "eth")
    #[serde(default = "default_label")]
    pub label: String,
    /// Map of covered component identifier → canonicalized value
    pub components: HashMap<String, String>,
}

fn default_label() -> String {
    "eth".to_string()
}

/// Decode the WAVS trigger data into an `Erc8128Input`.
///
/// Only `TriggerData::Raw` (JSON payload) is supported for this PoC.
pub fn decode_trigger_event(trigger_data: TriggerData) -> Result<Erc8128Input> {
    match trigger_data {
        TriggerData::Raw(data) => {
            serde_json::from_slice(&data).map_err(|e| anyhow::anyhow!("JSON parse error: {}", e))
        }
        _ => Err(anyhow::anyhow!(
            "erc8128-verifier only supports Raw trigger data (JSON payload)"
        )),
    }
}
