#[rustfmt::skip]
pub mod bindings;
mod trigger;

use crate::bindings::{export, host, Guest, TriggerAction, WasmResponse};
use alloy_primitives::keccak256;
use alloy_sol_macro::sol;
use alloy_sol_types::SolValue;
use anyhow::Result;
use serde::Deserialize;
use trigger::{decode_trigger_event, encode_trigger_output, Destination};

struct Component;
export!(Component with_types_in bindings);

// ABI-encodable output struct
sol! {
    struct LLMResult {
        uint64 triggerId;
        string response;
        bytes32 responseHash;
    }
}

/// Synchronous HTTP helpers using raw WASI bindings.
///
/// No wstd, no wavs-wasi-utils — raw WASI @0.2.x compatible with the WAVS node.
mod http {
    use crate::bindings::wasi::http::outgoing_handler;
    use crate::bindings::wasi::http::types::{
        Fields, IncomingBody, Method, OutgoingBody, OutgoingRequest, Scheme,
    };
    use crate::bindings::wasi::io::streams::StreamError;

    #[allow(dead_code)]
    pub fn get_json<T: serde::de::DeserializeOwned>(url: &str) -> Result<T, String> {
        let bytes = get(url)?;
        serde_json::from_slice(&bytes).map_err(|e| format!("JSON parse: {}", e))
    }

    #[allow(dead_code)]
    pub fn get(url: &str) -> Result<Vec<u8>, String> {
        let (scheme, authority, path_query) = parse_url(url)?;

        let headers = Fields::new();
        let req = OutgoingRequest::new(headers);
        req.set_method(&Method::Get).map_err(|_| "set method")?;
        req.set_scheme(Some(&scheme)).map_err(|_| "set scheme")?;
        req.set_authority(Some(&authority)).map_err(|_| "set authority")?;
        req.set_path_with_query(Some(&path_query)).map_err(|_| "set path")?;

        let fut = outgoing_handler::handle(req, None)
            .map_err(|e| format!("HTTP request failed: {:?}", e))?;

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
        let _trailers = IncomingBody::finish(body);

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
            .append(
                &"content-type".to_string(),
                &content_type.as_bytes().to_vec(),
            )
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

        // Write request body
        let out_body = req.body().map_err(|_| "req.body()")?;
        {
            let stream = out_body.write().map_err(|_| "body.write()")?;
            stream.subscribe().block();
            stream
                .write(body_bytes)
                .map_err(|e| format!("write: {:?}", e))?;
            stream.flush().map_err(|e| format!("flush: {:?}", e))?;
            stream.subscribe().block();
            drop(stream);
        }
        OutgoingBody::finish(out_body, None).map_err(|e| format!("finish body: {:?}", e))?;

        let fut = outgoing_handler::handle(req, None)
            .map_err(|e| format!("HTTP request: {:?}", e))?;
        fut.subscribe().block();

        let resp = fut
            .get()
            .ok_or("future not ready")?
            .map_err(|_| "response error")?
            .map_err(|e| format!("HTTP error: {:?}", e))?;

        let status = resp.status();
        if status < 200 || status >= 300 {
            return Err(format!("HTTP {status}"));
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
        let _trailers = IncomingBody::finish(resp_body);
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

// ── LLM API response types ────────────────────────────────────────────────────

/// Ollama /api/chat response
#[derive(Deserialize)]
struct OllamaResponse {
    message: OllamaMessage,
}

#[derive(Deserialize)]
struct OllamaMessage {
    content: String,
}

/// OpenAI /v1/chat/completions response
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

// ── Component impl ────────────────────────────────────────────────────────────

impl Guest for Component {
    fn run(action: TriggerAction) -> Result<Vec<WasmResponse>, String> {
        let (trigger_id, data_bytes, dest) =
            decode_trigger_event(action.data).map_err(|e| e.to_string())?;

        // Prompt is the trigger data as UTF-8 string
        let prompt = String::from_utf8(data_bytes)
            .map_err(|e| format!("UTF-8 decode: {e}"))?;

        // Read config from WAVS service config vars
        let api_url = host::config_var("llm_api_url")
            .unwrap_or_else(|| "http://host.docker.internal:11434".to_string());
        let model = host::config_var("llm_model")
            .unwrap_or_else(|| "llama3.2".to_string());
        let api_key = host::config_var("llm_api_key");

        let response = call_llm(&api_url, &model, api_key.as_deref(), &prompt)?;

        // Hash the response for on-chain attestation
        let response_hash = keccak256(response.as_bytes());

        let llm_result = LLMResult {
            triggerId: trigger_id,
            response: response.clone(),
            responseHash: response_hash.into(),
        };

        let output = match dest {
            Destination::Ethereum => vec![encode_trigger_output(trigger_id, &llm_result.abi_encode())],
            Destination::CliOutput => {
                vec![WasmResponse {
                    payload: format!(
                        "{{\"triggerId\":{},\"response\":{:?},\"responseHash\":\"0x{}\"}}",
                        trigger_id,
                        response,
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

fn call_llm(api_url: &str, model: &str, api_key: Option<&str>, prompt: &str) -> Result<String, String> {
    if api_key.is_some() {
        call_openai(api_url, model, api_key, prompt)
    } else {
        call_ollama(api_url, model, prompt)
    }
}

fn call_ollama(api_url: &str, model: &str, prompt: &str) -> Result<String, String> {
    let url = format!("{}/api/chat", api_url.trim_end_matches('/'));
    let body = serde_json::json!({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": false
    })
    .to_string();

    let resp: OllamaResponse = http::post_json(&url, &body, None)?;
    Ok(resp.message.content)
}

fn call_openai(api_url: &str, model: &str, api_key: Option<&str>, prompt: &str) -> Result<String, String> {
    let url = format!("{}/v1/chat/completions", api_url.trim_end_matches('/'));
    let body = serde_json::json!({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.0
    })
    .to_string();

    let resp: OpenAIResponse = http::post_json(&url, &body, api_key)?;
    resp.choices
        .into_iter()
        .next()
        .map(|c| c.message.content)
        .ok_or_else(|| "empty choices array from OpenAI".to_string())
}
