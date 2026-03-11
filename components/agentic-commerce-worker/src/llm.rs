use wavs_llm::{LLMClient, LlmOptionsBuilder, Message};

/// Call the LLM to complete a task and return the raw text output.
///
/// Model + URL from WAVS env vars:
///   WAVS_ENV_OLLAMA_API_URL  (default: http://localhost:11434)
///   WAVS_ENV_LLM_MODEL       (default: llama3.2)
///
/// temperature=0 for determinism across operators.
pub fn complete_task(system_prompt: &str, task: &str) -> Result<String, String> {
    let model = std::env::var("WAVS_ENV_LLM_MODEL")
        .unwrap_or_else(|_| "llama3.2".to_string());

    let options = LlmOptionsBuilder::new()
        .temperature(0.0)
        .build();

    let client = LLMClient::with_config(model, options);

    let msgs = vec![
        Message::system(system_prompt),
        Message::user(task),
    ];

    let response = client
        .chat(msgs)
        .send()
        .map_err(|e| format!("LLM request failed: {}", e))?;

    response
        .content
        .ok_or_else(|| "LLM returned empty response".to_string())
}
