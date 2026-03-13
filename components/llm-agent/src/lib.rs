#[rustfmt::skip]
pub mod bindings;
mod trigger;

use crate::bindings::wavs::types::core::LogLevel;
use crate::bindings::{export, host, Guest, TriggerAction, WasmResponse};
use alloy_primitives::keccak256;
use alloy_sol_macro::sol;
use alloy_sol_types::SolValue;
use serde::{Deserialize, Serialize};
use trigger::{decode_trigger_event, encode_trigger_output, Destination};

struct Component;
export!(Component with_types_in bindings);

// ── ABI output type ──────────────────────────────────────────────────────────

sol! {
    struct LLMResult {
        uint64 triggerId;
        string response;
        bytes32 responseHash;
    }
}

// ── Conversation & tool types ────────────────────────────────────────────────

#[derive(Serialize, Deserialize, Clone, Debug)]
struct Message {
    role: String,
    content: String,
}

/// A tool definition loaded from the `tools` config var.
#[derive(Serialize, Deserialize, Debug)]
struct ToolDef {
    /// Short name used by the LLM (e.g. "weather")
    name: String,
    /// WAVS service ID of the deployed tool component
    service_id: String,
    /// Human-readable description injected into the system prompt
    description: String,
    /// Optional: workflow ID to use (defaults to "default")
    #[serde(default = "default_workflow")]
    workflow_id: String,
}

fn default_workflow() -> String {
    "default".to_string()
}

/// Parsed from the LLM response when it wants to call a tool.
#[derive(Deserialize, Debug)]
struct ToolCallRequest {
    tool: String,
    args: serde_json::Value,
}

// ── LLM API response types ───────────────────────────────────────────────────

#[derive(Deserialize)]
struct OllamaResponse {
    message: OllamaMessage,
}

#[derive(Deserialize)]
struct OllamaMessage {
    content: String,
}

#[derive(Deserialize)]
struct OpenAIResponse {
    choices: Vec<OpenAIChoice>,
}

#[derive(Deserialize)]
struct OpenAIChoice {
    message: OpenAIMessage,
}

#[derive(Deserialize)]
struct OpenAIMessage {
    content: String,
}

// Anthropic Messages API
#[derive(Deserialize)]
struct AnthropicResponse {
    content: Vec<AnthropicContent>,
}

#[derive(Deserialize)]
struct AnthropicContent {
    #[serde(rename = "type")]
    kind: String,
    text: Option<String>,
}

// ── Component impl ────────────────────────────────────────────────────────────

impl Guest for Component {
    fn run(action: TriggerAction) -> Result<Vec<WasmResponse>, String> {
        let (trigger_id, data_bytes, dest) =
            decode_trigger_event(action.data).map_err(|e| e.to_string())?;

        let prompt = String::from_utf8(data_bytes)
            .map_err(|e| format!("UTF-8 decode: {e}"))?;

        // ── Config ────────────────────────────────────────────────────────────
        let api_url = host::config_var("llm_api_url")
            .unwrap_or_else(|| "http://host.docker.internal:11434".to_string());
        let model = host::config_var("llm_model")
            .unwrap_or_else(|| "llama3.2".to_string());
        let api_key = host::config_var("llm_api_key");
        let tools_json = host::config_var("tools")
            .unwrap_or_else(|| "[]".to_string());
        let max_tool_calls: usize = host::config_var("max_tool_calls")
            .and_then(|s| s.parse().ok())
            .unwrap_or(5);
        let wavs_url = host::config_var("wavs_node_url")
            .unwrap_or_else(|| "http://host.docker.internal:8041".to_string());

        host::log(LogLevel::Info, &format!("llm-agent: prompt = {:?}", &prompt));

        // ── Parse tool manifest ───────────────────────────────────────────────
        let tools: Vec<ToolDef> = serde_json::from_str(&tools_json)
            .map_err(|e| format!("parse tools config: {e}"))?;

        host::log(
            LogLevel::Info,
            &format!("llm-agent: {} tool(s) available: {:?}", tools.len(),
                tools.iter().map(|t| &t.name).collect::<Vec<_>>()),
        );

        // ── Build system prompt ───────────────────────────────────────────────
        let system_prompt = build_system_prompt(&tools);

        // ── Initialize conversation ───────────────────────────────────────────
        let mut messages: Vec<Message> = vec![
            Message { role: "system".to_string(), content: system_prompt },
            Message { role: "user".to_string(), content: prompt.clone() },
        ];

        let mut final_response = String::new();
        let mut iterations = 0;

        // ── ReAct tool loop ───────────────────────────────────────────────────
        loop {
            host::log(LogLevel::Info, &format!("llm-agent: LLM call #{}", iterations + 1));

            let response = call_llm(&api_url, &model, api_key.as_deref(), &messages)?;

            let preview = &response[..response.len().min(300)];
            host::log(LogLevel::Info, &format!("llm-agent: response = {:?}", preview));

            let trimmed = response.trim();

            // Check for TOOL_CALL — scan all lines (some models batch multiple calls;
            // we execute the first one found per iteration and loop back for the rest)
            let first_tool_line = trimmed
                .lines()
                .find(|l| l.trim_start().starts_with("TOOL_CALL:"));

            if let Some(tool_line) = first_tool_line {
                if iterations >= max_tool_calls {
                    return Err(format!(
                        "llm-agent: exceeded max_tool_calls ({})", max_tool_calls
                    ));
                }

                let json_part = tool_line
                    .trim_start()
                    .strip_prefix("TOOL_CALL:")
                    .unwrap_or("")
                    .trim();

                let tc: ToolCallRequest = serde_json::from_str(json_part)
                    .map_err(|e| format!("parse TOOL_CALL JSON: {e} — got: {:?}", json_part))?;

                host::log(
                    LogLevel::Info,
                    &format!("llm-agent: tool call → {} with args {}", tc.tool, tc.args),
                );

                // Find tool service_id
                let tool_def = tools
                    .iter()
                    .find(|t| t.name == tc.tool)
                    .ok_or_else(|| format!("unknown tool: {} (available: {:?})",
                        tc.tool, tools.iter().map(|t| &t.name).collect::<Vec<_>>()))?;

                // Dispatch tool and get result
                let result_json = dispatch_tool(
                    &wavs_url,
                    &tool_def.service_id,
                    &tool_def.workflow_id,
                    &tc.args,
                )
                .map_err(|e| format!("tool {} failed: {}", tc.tool, e))?;

                host::log(
                    LogLevel::Info,
                    &format!("llm-agent: tool {} result = {:?}",
                        tc.tool, &result_json[..result_json.len().min(300)]),
                );

                // Append tool call + result to conversation
                messages.push(Message {
                    role: "assistant".to_string(),
                    content: response,
                });
                messages.push(Message {
                    role: "user".to_string(),
                    content: format!("Tool result for `{}`:\n{}", tc.tool, result_json),
                });

                iterations += 1;
            } else {
                // No tool call → final answer
                final_response = response;
                break;
            }
        }

        host::log(
            LogLevel::Info,
            &format!("llm-agent: final answer after {} tool call(s): {:?}",
                iterations, &final_response[..final_response.len().min(300)]),
        );

        // ── ABI encode output ─────────────────────────────────────────────────
        let response_hash = keccak256(final_response.as_bytes());

        let llm_result = LLMResult {
            triggerId: trigger_id,
            response: final_response.clone(),
            responseHash: response_hash.into(),
        };

        let output = match dest {
            Destination::Ethereum => {
                vec![encode_trigger_output(trigger_id, &llm_result.abi_encode())]
            }
            Destination::CliOutput => {
                vec![WasmResponse {
                    payload: format!(
                        "{{\"triggerId\":{},\"response\":{:?},\"responseHash\":\"0x{}\"}}",
                        trigger_id,
                        final_response,
                        hex::encode(response_hash.as_slice())
                    )
                    .into_bytes(),
                    ordering: None,
                    event_id_salt: None,
                }]
            }
        };

        Ok(output)
    }
}

// ── Tool dispatch ─────────────────────────────────────────────────────────────

/// Fire a WAVS trigger for a tool, wait for completion, then read the result
/// from the KV store at `{service_id}/tool/result`.
fn dispatch_tool(
    wavs_url: &str,
    service_id: &str,
    workflow_id: &str,
    args: &serde_json::Value,
) -> Result<String, String> {
    // Serialize args as raw bytes (tool receives them as trigger data)
    let args_bytes = serde_json::to_vec(args)
        .map_err(|e| format!("serialize args: {e}"))?;

    // WAVS trigger body: Raw bytes data array
    let data_array: Vec<serde_json::Value> = args_bytes
        .iter()
        .map(|&b| serde_json::Value::Number(serde_json::Number::from(b)))
        .collect();

    let trigger_body = serde_json::json!({
        "service_id": service_id,
        "workflow_id": workflow_id,
        "trigger": "manual",
        "data": {"Raw": data_array},
        "count": 1,
        "wait_for_completion": true
    });

    let trigger_body_str = serde_json::to_string(&trigger_body)
        .map_err(|e| format!("serialize trigger body: {e}"))?;

    // POST to /dev/triggers (blocks until tool completes)
    let trigger_url = format!("{}/dev/triggers", wavs_url.trim_end_matches('/'));
    http::post(&trigger_url, trigger_body_str.as_bytes(), "application/json", None)
        .map_err(|e| format!("POST /dev/triggers: {}", e))?;

    // Read result from KV: /dev/kv/{service_id}/tool/result
    let kv_url = format!(
        "{}/dev/kv/{}/tool/result",
        wavs_url.trim_end_matches('/'),
        service_id
    );
    let kv_bytes = http::get(&kv_url)
        .map_err(|e| format!("GET /dev/kv/{}/tool/result: {}", service_id, e))?;

    String::from_utf8(kv_bytes)
        .map_err(|e| format!("tool result not valid UTF-8: {e}"))
}

// ── System prompt ─────────────────────────────────────────────────────────────

fn build_system_prompt(tools: &[ToolDef]) -> String {
    if tools.is_empty() {
        return "You are a helpful assistant. Answer concisely.".to_string();
    }

    let mut prompt = String::from(
        "You are a helpful assistant with access to real-time tools.\n\n\
         Available tools:\n",
    );

    for tool in tools {
        prompt.push_str(&format!("- {}: {}\n", tool.name, tool.description));
    }

    prompt.push_str(
        "\nRules:\n\
         1. Call ONE tool at a time. Respond with ONLY this exact line (nothing else):\n\
            TOOL_CALL: {\"tool\": \"<name>\", \"args\": {<json arguments>}}\n\
         2. Wait for the tool result before calling the next tool.\n\
         3. After receiving a tool result, call another tool if needed, or give your final answer.\n\
         4. When you have all the information needed, respond normally (not with TOOL_CALL).\n\
         5. Be concise. One sentence answers preferred unless detail is requested.\n\
         6. Do not fabricate data — always use tool results for real-time information.",
    );

    prompt
}

// ── LLM API ───────────────────────────────────────────────────────────────────

fn call_llm(
    api_url: &str,
    model: &str,
    api_key: Option<&str>,
    messages: &[Message],
) -> Result<String, String> {
    if api_url.contains("anthropic.com") {
        call_anthropic(api_url, model, api_key, messages)
    } else if api_key.is_some() {
        call_openai(api_url, model, api_key, messages)
    } else {
        call_ollama(api_url, model, messages)
    }
}

fn call_ollama(api_url: &str, model: &str, messages: &[Message]) -> Result<String, String> {
    let url = format!("{}/api/chat", api_url.trim_end_matches('/'));
    let body = serde_json::json!({
        "model": model,
        "messages": messages,
        "stream": false,
        "options": { "temperature": 0.0 }
    })
    .to_string();

    let resp: OllamaResponse = http::post_json(&url, &body, None)?;
    Ok(resp.message.content)
}

fn call_openai(
    api_url: &str,
    model: &str,
    api_key: Option<&str>,
    messages: &[Message],
) -> Result<String, String> {
    let url = format!("{}/v1/chat/completions", api_url.trim_end_matches('/'));
    let body = serde_json::json!({
        "model": model,
        "messages": messages,
        "temperature": 0.0
    })
    .to_string();

    let resp: OpenAIResponse = http::post_json(&url, &body, api_key)?;
    resp.choices
        .into_iter()
        .next()
        .map(|c| c.message.content)
        .ok_or_else(|| "empty choices from LLM API".to_string())
}

fn call_anthropic(
    api_url: &str,
    model: &str,
    api_key: Option<&str>,
    messages: &[Message],
) -> Result<String, String> {
    let url = format!("{}/v1/messages", api_url.trim_end_matches('/'));

    // Anthropic requires system message extracted from messages array
    let system = messages
        .iter()
        .find(|m| m.role == "system")
        .map(|m| m.content.as_str())
        .unwrap_or("You are a helpful assistant.");

    let non_system: Vec<&Message> = messages.iter().filter(|m| m.role != "system").collect();

    let body = serde_json::json!({
        "model": model,
        "max_tokens": 1024,
        "system": system,
        "messages": non_system,
        "temperature": 0.0
    })
    .to_string();

    // Anthropic uses x-api-key + anthropic-version headers
    let resp_bytes = http::post_anthropic(&url, body.as_bytes(), api_key)?;
    let resp: AnthropicResponse = serde_json::from_slice(&resp_bytes)
        .map_err(|e| format!("Anthropic JSON parse: {e}"))?;

    resp.content
        .into_iter()
        .find(|c| c.kind == "text")
        .and_then(|c| c.text)
        .ok_or_else(|| "no text content in Anthropic response".to_string())
}

// ── HTTP helpers (raw WASI — no wstd, WASI @0.2.x compatible) ────────────────

mod http {
    use crate::bindings::wasi::http::outgoing_handler;
    use crate::bindings::wasi::http::types::{
        Fields, IncomingBody, Method, OutgoingBody, OutgoingRequest, Scheme,
    };
    use crate::bindings::wasi::io::streams::StreamError;

    pub fn get_json<T: serde::de::DeserializeOwned>(url: &str) -> Result<T, String> {
        let bytes = get(url)?;
        serde_json::from_slice(&bytes).map_err(|e| format!("JSON parse: {}", e))
    }

    pub fn get(url: &str) -> Result<Vec<u8>, String> {
        let (scheme, authority, path_query) = parse_url(url)?;

        let headers = Fields::new();
        let req = OutgoingRequest::new(headers);
        req.set_method(&Method::Get).map_err(|_| "set method")?;
        req.set_scheme(Some(&scheme)).map_err(|_| "set scheme")?;
        req.set_authority(Some(&authority)).map_err(|_| "set authority")?;
        req.set_path_with_query(Some(&path_query)).map_err(|_| "set path")?;

        let fut = outgoing_handler::handle(req, None)
            .map_err(|e| format!("HTTP GET failed: {:?}", e))?;
        fut.subscribe().block();

        let resp = fut
            .get()
            .ok_or("future not ready after block")?
            .map_err(|_| "response future error")?
            .map_err(|e| format!("HTTP error: {:?}", e))?;

        let status = resp.status();
        if status < 200 || status >= 300 {
            return Err(format!("HTTP {}: {}", status, url));
        }

        let body = resp.consume().map_err(|_| "consume body")?;
        let stream = body.stream().map_err(|_| "body stream")?;

        let mut bytes = Vec::new();
        let mut empty_reads = 0;
        loop {
            stream.subscribe().block();
            match stream.read(65536) {
                Ok(chunk) if chunk.is_empty() => {
                    empty_reads += 1;
                    if empty_reads > 32 {
                        break;
                    }
                }
                Ok(chunk) => {
                    bytes.extend_from_slice(&chunk);
                    empty_reads = 0;
                }
                Err(StreamError::Closed) => break,
                Err(StreamError::LastOperationFailed(e)) => {
                    return Err(format!("read error: {:?}", e));
                }
            }
        }
        drop(stream);
        // NOTE: do NOT call IncomingBody::finish() — causes "resource has children" panic
        drop(body);

        Ok(bytes)
    }

    pub fn post_json<T: serde::de::DeserializeOwned>(
        url: &str,
        body: &str,
        api_key: Option<&str>,
    ) -> Result<T, String> {
        let bytes = post(url, body.as_bytes(), "application/json", api_key)?;
        serde_json::from_slice(&bytes).map_err(|e| format!("JSON parse: {e}"))
    }

    pub fn post(
        url: &str,
        body_bytes: &[u8],
        content_type: &str,
        api_key: Option<&str>,
    ) -> Result<Vec<u8>, String> {
        let (scheme, authority, path_query) = parse_url(url)?;

        let headers = Fields::new();
        headers
            .append(&"content-type".to_string(), &content_type.as_bytes().to_vec())
            .map_err(|e| format!("content-type header: {:?}", e))?;
        if let Some(key) = api_key {
            headers
                .append(
                    &"authorization".to_string(),
                    &format!("Bearer {key}").into_bytes(),
                )
                .map_err(|e| format!("auth header: {:?}", e))?;
        }

        let req = OutgoingRequest::new(headers);
        req.set_method(&Method::Post).map_err(|_| "set method")?;
        req.set_scheme(Some(&scheme)).map_err(|_| "set scheme")?;
        req.set_authority(Some(&authority)).map_err(|_| "set authority")?;
        req.set_path_with_query(Some(&path_query)).map_err(|_| "set path")?;

        let out_body = req.body().map_err(|_| "req.body()")?;
        {
            let stream = out_body.write().map_err(|_| "body.write()")?;
            stream.subscribe().block();
            stream.write(body_bytes).map_err(|e| format!("write: {:?}", e))?;
            stream.flush().map_err(|e| format!("flush: {:?}", e))?;
            stream.subscribe().block();
            drop(stream);
        }
        OutgoingBody::finish(out_body, None).map_err(|e| format!("finish body: {:?}", e))?;

        let fut = outgoing_handler::handle(req, None)
            .map_err(|e| format!("HTTP POST failed: {:?}", e))?;
        fut.subscribe().block();

        let resp = fut
            .get()
            .ok_or("future not ready")?
            .map_err(|_| "response error")?
            .map_err(|e| format!("HTTP error: {:?}", e))?;

        let status = resp.status();
        if status < 200 || status >= 300 {
            return Err(format!("HTTP POST {} → status {}", url, status));
        }

        let resp_body = resp.consume().map_err(|_| "consume")?;
        let stream = resp_body.stream().map_err(|_| "stream")?;
        let mut bytes = Vec::new();
        let mut empty_reads = 0;
        loop {
            stream.subscribe().block();
            match stream.read(65536) {
                Ok(chunk) if chunk.is_empty() => {
                    empty_reads += 1;
                    if empty_reads > 32 {
                        break;
                    }
                }
                Ok(chunk) => {
                    bytes.extend_from_slice(&chunk);
                    empty_reads = 0;
                }
                Err(StreamError::Closed) => break,
                Err(StreamError::LastOperationFailed(e)) => {
                    return Err(format!("read: {:?}", e));
                }
            }
        }
        // Must drop stream before body — body still has stream as a child resource
        drop(stream);
        // NOTE: do NOT call IncomingBody::finish() — causes "resource has children" panic
        drop(resp_body);
        Ok(bytes)
    }

    /// POST with Anthropic-specific headers (x-api-key + anthropic-version).
    pub fn post_anthropic(
        url: &str,
        body_bytes: &[u8],
        api_key: Option<&str>,
    ) -> Result<Vec<u8>, String> {
        let (scheme, authority, path_query) = parse_url(url)?;

        let headers = Fields::new();
        headers
            .append(&"content-type".to_string(), &b"application/json".to_vec())
            .map_err(|e| format!("content-type: {:?}", e))?;
        headers
            .append(
                &"anthropic-version".to_string(),
                &b"2023-06-01".to_vec(),
            )
            .map_err(|e| format!("anthropic-version: {:?}", e))?;
        if let Some(key) = api_key {
            headers
                .append(&"x-api-key".to_string(), &key.as_bytes().to_vec())
                .map_err(|e| format!("x-api-key: {:?}", e))?;
        }

        let req = OutgoingRequest::new(headers);
        req.set_method(&Method::Post).map_err(|_| "set method")?;
        req.set_scheme(Some(&scheme)).map_err(|_| "set scheme")?;
        req.set_authority(Some(&authority)).map_err(|_| "set authority")?;
        req.set_path_with_query(Some(&path_query)).map_err(|_| "set path")?;

        let out_body = req.body().map_err(|_| "req.body()")?;
        {
            let stream = out_body.write().map_err(|_| "body.write()")?;
            stream.subscribe().block();
            stream.write(body_bytes).map_err(|e| format!("write: {:?}", e))?;
            stream.flush().map_err(|e| format!("flush: {:?}", e))?;
            stream.subscribe().block();
            drop(stream);
        }
        OutgoingBody::finish(out_body, None).map_err(|e| format!("finish body: {:?}", e))?;

        let fut = outgoing_handler::handle(req, None)
            .map_err(|e| format!("HTTP POST (Anthropic) failed: {:?}", e))?;
        fut.subscribe().block();

        let resp = fut
            .get()
            .ok_or("future not ready")?
            .map_err(|_| "response error")?
            .map_err(|e| format!("HTTP error: {:?}", e))?;

        let status = resp.status();
        if status < 200 || status >= 300 {
            // Try to read the error body for better diagnostics
            let err_body = resp.consume().map_err(|_| "consume")?;
            let err_stream = err_body.stream().map_err(|_| "stream")?;
            let mut err_bytes = Vec::new();
            loop {
                err_stream.subscribe().block();
                match err_stream.read(4096) {
                    Ok(chunk) if chunk.is_empty() => break,
                    Ok(chunk) => err_bytes.extend_from_slice(&chunk),
                    Err(_) => break,
                }
            }
            drop(err_stream);
            drop(err_body);
            let err_msg = String::from_utf8_lossy(&err_bytes).to_string();
            return Err(format!("Anthropic HTTP {status}: {err_msg}"));
        }

        let resp_body = resp.consume().map_err(|_| "consume")?;
        let stream = resp_body.stream().map_err(|_| "stream")?;
        let mut bytes = Vec::new();
        let mut empty_reads = 0;
        loop {
            stream.subscribe().block();
            match stream.read(65536) {
                Ok(chunk) if chunk.is_empty() => {
                    empty_reads += 1;
                    if empty_reads > 32 { break; }
                }
                Ok(chunk) => {
                    bytes.extend_from_slice(&chunk);
                    empty_reads = 0;
                }
                Err(StreamError::Closed) => break,
                Err(StreamError::LastOperationFailed(e)) => {
                    return Err(format!("read: {:?}", e));
                }
            }
        }
        // Must drop stream before body — body still has stream as a child resource
        drop(stream);
        // NOTE: do NOT call IncomingBody::finish() — causes "resource has children" panic
        drop(resp_body);
        Ok(bytes)
    }

    pub fn parse_url(url: &str) -> Result<(Scheme, String, String), String> {
        let (scheme, rest) = if let Some(r) = url.strip_prefix("https://") {
            (Scheme::Https, r)
        } else if let Some(r) = url.strip_prefix("http://") {
            (Scheme::Http, r)
        } else {
            return Err(format!("unsupported URL scheme: {}", url));
        };

        let (authority, path_query) = match rest.find('/') {
            Some(pos) => (rest[..pos].to_string(), rest[pos..].to_string()),
            None => (rest.to_string(), "/".to_string()),
        };

        Ok((scheme, authority, path_query))
    }
}
