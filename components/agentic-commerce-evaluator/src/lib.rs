#[rustfmt::skip]
pub mod bindings;
mod http;
mod trigger;

use crate::bindings::{export, Guest, TriggerAction, WasmResponse};
use crate::bindings::wavs::types::core::LogLevel;
use crate::bindings::host;
use trigger::{decode_trigger_event, encode_evaluation};

struct Component;
export!(Component with_types_in bindings);

impl Guest for Component {
    fn run(action: TriggerAction) -> Result<Vec<WasmResponse>, String> {
        host::log(LogLevel::Info, "agentic-commerce-evaluator: trigger received, decoding event");

        let event = decode_trigger_event(action.data).map_err(|e| {
            host::log(LogLevel::Error, &format!("decode_trigger_event failed: {}", e));
            e.to_string()
        })?;

        host::log(LogLevel::Info, &format!(
            "JobSubmitted: job_id={}, provider={}, url={}",
            event.job_id, event.provider, event.url
        ));

        // ── 1. Fetch the target URL ──────────────────────────────────────
        let body = http::get(&event.url).map_err(|e| {
            host::log(LogLevel::Error, &format!("HTTP GET '{}' failed: {}", event.url, e));
            format!("HTTP GET '{}': {}", event.url, e)
        })?;

        host::log(LogLevel::Info, &format!(
            "Fetched URL: {} ({} bytes)",
            event.url, body.len()
        ));

        // ── 2. Compute keccak256 of the response body ────────────────────
        let computed: [u8; 32] = *alloy_primitives::keccak256(&body);

        host::log(LogLevel::Debug, &format!(
            "keccak256(body) = 0x{}",
            hex::encode(computed)
        ));

        // ── 3. Compare against the provider's deliverable ───────────────
        let is_complete = computed == event.deliverable;

        host::log(LogLevel::Info, &format!(
            "Evaluation: job_id={} is_complete={} | computed=0x{} deliverable=0x{}",
            event.job_id, is_complete,
            hex::encode(computed),
            hex::encode(event.deliverable)
        ));

        // ── 4. Encode verdict for AgenticCommerceEvaluator ──────────────
        host::log(LogLevel::Info, &format!(
            "Encoding verdict and returning response for job_id={}",
            event.job_id
        ));

        Ok(vec![encode_evaluation(event.job_id, is_complete, computed)])
    }
}
