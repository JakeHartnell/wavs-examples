use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use wavs_llm::{LLMClient, LlmOptionsBuilder, Message};

/// Structured evaluation response from the LLM.
/// schemars drives the JSON schema sent to the model — field names and
/// doc-comments become part of the schema, so keep them clear.
#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct JobEvaluation {
    /// Whether the deliverable satisfies the job requirements (true = approve payment)
    pub approved: bool,

    /// Quality score 0-100 (approve if >= 70)
    pub score: u8,

    /// One-sentence explanation of the verdict
    pub reasoning: String,
}

/// Call the configured Ollama model and return a structured evaluation.
///
/// Model + URL are read from WAVS env vars:
///   WAVS_ENV_OLLAMA_API_URL  (default: http://localhost:11434)
///   WAVS_ENV_LLM_MODEL       (default: llama3.2)
///
/// temperature=0 is critical for determinism across operators.
pub fn evaluate_job(system_prompt: &str, user_prompt: &str) -> Result<JobEvaluation, String> {
    let model = std::env::var("WAVS_ENV_LLM_MODEL")
        .unwrap_or_else(|_| "llama3.2".to_string());

    let options = LlmOptionsBuilder::new()
        .temperature(0.0)
        .build();

    let client = LLMClient::with_config(model, options);

    let msgs = vec![
        Message::system(system_prompt),
        Message::user(user_prompt),
    ];

    let result = client
        .chat_structured::<JobEvaluation>(msgs)
        .send()
        .map_err(|e| format!("LLM request failed: {}", e))?;

    Ok(result)
}
