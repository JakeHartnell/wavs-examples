#[rustfmt::skip]
pub mod bindings;
mod http;
mod llm;
mod trigger;

use crate::bindings::wavs::types::core::LogLevel;
use crate::bindings::{export, host, Guest, TriggerAction, WasmResponse};
use trigger::{decode_trigger_event, encode_evaluation};

struct Component;
export!(Component with_types_in bindings);

impl Guest for Component {
    fn run(action: TriggerAction) -> Result<Vec<WasmResponse>, String> {
        host::log(LogLevel::Info, "llm-commerce-evaluator: trigger received, decoding event");

        let event = decode_trigger_event(action.data).map_err(|e| {
            host::log(LogLevel::Error, &format!("decode_trigger_event failed: {}", e));
            e.to_string()
        })?;

        host::log(LogLevel::Info, &format!(
            "JobSubmitted: job_id={}, provider={}, result_uri={}",
            event.job_id, event.provider, event.result_uri
        ));

        // ── 1. Fetch the worker's published output ───────────────────────
        let body = http::get(&event.result_uri).map_err(|e| {
            host::log(LogLevel::Error, &format!("HTTP GET '{}' failed: {}", event.result_uri, e));
            format!("HTTP GET '{}': {}", event.result_uri, e)
        })?;

        host::log(LogLevel::Info, &format!(
            "Fetched worker output: {} ({} bytes)",
            event.result_uri, body.len()
        ));

        // ── 2. Get system prompt from config (operator-configurable) ─────
        let system_prompt = crate::bindings::host::config_var("LLM_SYSTEM_PROMPT")
            .unwrap_or_else(|| DEFAULT_SYSTEM_PROMPT.to_string());

        host::log(LogLevel::Debug, &format!(
            "Using system prompt ({} chars)", system_prompt.len()
        ));

        // ── 3. Build user prompt from job description + deliverable ──────
        let deliverable_text = String::from_utf8_lossy(&body);
        let user_prompt = format!(
            "Job description: {}\n\nDeliverable URL: {}\n\nDeliverable content:\n{}",
            event.job_description, event.result_uri, deliverable_text
        );

        // ── 4. Call LLM for structured evaluation ────────────────────────
        host::log(LogLevel::Info, "Calling LLM for evaluation...");

        let evaluation = llm::evaluate_job(&system_prompt, &user_prompt).map_err(|e| {
            host::log(LogLevel::Error, &format!("LLM evaluation failed: {}", e));
            e
        })?;

        host::log(LogLevel::Info, &format!(
            "LLM verdict: job_id={} approved={} score={}/100 reasoning=\"{}\"",
            event.job_id, evaluation.approved, evaluation.score, evaluation.reasoning
        ));

        // ── 5. Encode verdict + score + reasoning for on-chain submission ─
        host::log(LogLevel::Info, &format!(
            "Encoding evaluation result for job_id={}",
            event.job_id
        ));

        Ok(vec![encode_evaluation(
            event.job_id,
            evaluation.approved,
            evaluation.score,
            evaluation.reasoning,
        )])
    }
}

/// Default system prompt — operators can override via WAVS_ENV_LLM_SYSTEM_PROMPT
const DEFAULT_SYSTEM_PROMPT: &str = "\
You are a neutral, impartial evaluator for agentic commerce jobs. \
Your role is to assess whether a provider has delivered what was promised. \
\n\n\
You will receive a job description and the content retrieved from the provider's deliverable URL. \
Evaluate whether the deliverable satisfies the job description. \
\n\n\
Be strict but fair. Score on a 0-100 scale where:\n\
- 90-100: Excellent, fully satisfies requirements\n\
- 70-89: Good, mostly satisfies requirements with minor gaps\n\
- 50-69: Partial, some requirements met but significant gaps\n\
- 0-49: Inadequate, fails to satisfy core requirements\n\
\n\
Approve (approved=true) if score >= 70.\
";
