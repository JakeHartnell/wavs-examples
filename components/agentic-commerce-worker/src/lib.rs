#[rustfmt::skip]
pub mod bindings;
mod http;
mod llm;
mod trigger;

use crate::bindings::wavs::types::core::LogLevel;
use crate::bindings::{export, host, Guest, TriggerAction, WasmResponse};
use trigger::{decode_trigger_event, encode_worker_result};

struct Component;
export!(Component with_types_in bindings);

impl Guest for Component {
    fn run(action: TriggerAction) -> Result<Vec<WasmResponse>, String> {
        host::log(LogLevel::Info, "agentic-commerce-worker: trigger received, decoding event");

        let event = decode_trigger_event(action.data).map_err(|e| {
            host::log(LogLevel::Error, &format!("decode_trigger_event failed: {}", e));
            e.to_string()
        })?;

        host::log(LogLevel::Info, &format!(
            "JobFunded: job_id={}, client={}, task=\"{}\"",
            event.job_id, event.client, event.description
        ));

        // ── 1. Get system prompt from config (operator-configurable) ─────
        let system_prompt = host::config_var("WORKER_SYSTEM_PROMPT")
            .unwrap_or_else(|| DEFAULT_SYSTEM_PROMPT.to_string());

        // ── 2. Call LLM to do the actual work ────────────────────────────
        host::log(LogLevel::Info, "Calling LLM to fulfill task...");

        let llm_output = llm::complete_task(&system_prompt, &event.description).map_err(|e| {
            host::log(LogLevel::Error, &format!("LLM task failed: {}", e));
            e
        })?;

        host::log(LogLevel::Info, &format!(
            "LLM completed task ({} chars)", llm_output.len()
        ));
        host::log(LogLevel::Debug, &format!("LLM output: {}", &llm_output[..llm_output.len().min(200)]));

        // ── 3. Publish output to paste.rs ────────────────────────────────
        host::log(LogLevel::Info, "Publishing result to paste.rs...");

        let result_uri = http::publish_paste(&llm_output).map_err(|e| {
            host::log(LogLevel::Error, &format!("Failed to publish paste: {}", e));
            e
        })?;

        host::log(LogLevel::Info, &format!("Result published: {}", result_uri));

        // ── 4. Compute deliverable hash ───────────────────────────────────
        let deliverable: [u8; 32] = *alloy_primitives::keccak256(llm_output.as_bytes());

        host::log(LogLevel::Info, &format!(
            "Deliverable hash: 0x{} — submitting for job_id={}",
            hex::encode(deliverable), event.job_id
        ));

        // ── 5. Encode for AgenticCommerceWorker.handleSignedEnvelope ──────
        Ok(vec![encode_worker_result(event.job_id, deliverable, result_uri)])
    }
}

/// Default system prompt — operators can override via WAVS_ENV_WORKER_SYSTEM_PROMPT
const DEFAULT_SYSTEM_PROMPT: &str = "\
You are a skilled AI worker fulfilling jobs in an agentic commerce marketplace. \
You will receive a task description and must complete it to the best of your ability. \
Be thorough, accurate, and professional. \
Respond with only the completed work output — no preamble, no meta-commentary.\
";
