#[rustfmt::skip]
pub mod bindings;
mod http;
mod trigger;

use crate::bindings::{export, Guest, TriggerAction, WasmResponse};
use anyhow::Result;
use trigger::{decode_trigger_event, encode_evaluation};

struct Component;
export!(Component with_types_in bindings);

impl Guest for Component {
    fn run(action: TriggerAction) -> Result<Vec<WasmResponse>, String> {
        let event = decode_trigger_event(action.data).map_err(|e| e.to_string())?;

        // ── 1. Fetch the target URL ──────────────────────────────────────
        let body = http::get(&event.url)
            .map_err(|e| format!("HTTP GET '{}': {}", event.url, e))?;

        // ── 2. Compute keccak256 of the response body ────────────────────
        use alloy_primitives::keccak256;
        let computed: [u8; 32] = *keccak256(&body);

        // ── 3. Compare against the provider's deliverable ───────────────
        let is_complete = computed == event.deliverable;

        println!(
            "jobId={} provider={} deliverable=0x{} computed=0x{} match={}",
            event.job_id,
            event.provider,
            hex::encode(event.deliverable),
            hex::encode(computed),
            is_complete,
        );

        // ── 4. Encode verdict for AgenticCommerceEvaluator.handleSignedEnvelope
        Ok(vec![encode_evaluation(event.job_id, is_complete, computed)])
    }
}
