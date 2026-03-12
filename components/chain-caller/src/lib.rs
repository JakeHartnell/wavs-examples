#[rustfmt::skip]
pub mod bindings;
mod trigger;

use crate::bindings::wavs::types::core::LogLevel;
use crate::bindings::{export, host, Guest, TriggerAction, WasmResponse};
use trigger::{decode_trigger_event, encode_trigger_output, Destination};

struct Component;
export!(Component with_types_in bindings);

/// Synchronous HTTP helpers using raw WASI bindings.
mod http {
    use crate::bindings::wasi::http::outgoing_handler;
    use crate::bindings::wasi::http::types::{
        Fields, Method, OutgoingBody, OutgoingRequest, Scheme,
    };
    use crate::bindings::wasi::io::streams::StreamError;

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
        // NOTE: do NOT call IncomingBody::finish() on response body — causes StreamError_Closed panic
        drop(body);

        Ok(bytes)
    }

    pub fn post(url: &str, body_bytes: &[u8], content_type: &str) -> Result<Vec<u8>, String> {
        let (scheme, authority, path_query) = parse_url(url)?;

        let headers = Fields::new();
        headers
            .append(
                &"content-type".to_string(),
                &content_type.as_bytes().to_vec(),
            )
            .map_err(|e| format!("content-type header: {:?}", e))?;

        let req = OutgoingRequest::new(headers);
        req.set_method(&Method::Post).map_err(|_| "set method")?;
        req.set_scheme(Some(&scheme)).map_err(|_| "set scheme")?;
        req.set_authority(Some(&authority)).map_err(|_| "set authority")?;
        req.set_path_with_query(Some(&path_query)).map_err(|_| "set path")?;

        // Write request body
        let out_body = req.body().map_err(|_| "get body")?;
        {
            let stream = out_body.write().map_err(|_| "get write stream")?;
            stream.write(body_bytes).map_err(|e| format!("write: {:?}", e))?;
            stream.flush().map_err(|e| format!("flush: {:?}", e))?;
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
            return Err(format!("HTTP POST {}: status {}", url, status));
        }

        let resp_body = resp.consume().map_err(|_| "consume response body")?;
        let stream = resp_body.stream().map_err(|_| "response body stream")?;
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
                    return Err(format!("read response: {:?}", e));
                }
            }
        }
        drop(stream);
        // NOTE: do NOT call IncomingBody::finish() — causes StreamError_Closed panic
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

impl Guest for Component {
    fn run(action: TriggerAction) -> Result<Vec<WasmResponse>, String> {
        let (trigger_id, data, dest) =
            decode_trigger_event(action.data).map_err(|e| e.to_string())?;

        let caller_input = String::from_utf8_lossy(&data).to_string();

        // Read config vars
        let callee_service_id = host::config_var("callee_service_id")
            .ok_or("callee_service_id config var is required")?;
        let callee_workflow_id = host::config_var("callee_workflow_id")
            .unwrap_or_else(|| "default".to_string());
        let wavs_node_url = host::config_var("wavs_node_url")
            .unwrap_or_else(|| "http://host.docker.internal:8041".to_string());

        host::log(
            LogLevel::Info,
            &format!(
                "chain-caller: firing callee_service_id={} workflow={} with {} bytes",
                callee_service_id,
                callee_workflow_id,
                data.len()
            ),
        );

        // Build the trigger POST body
        let data_array: Vec<serde_json::Value> = data
            .iter()
            .map(|&b| serde_json::Value::Number(serde_json::Number::from(b)))
            .collect();

        let trigger_body = serde_json::json!({
            "service_id": callee_service_id,
            "workflow_id": callee_workflow_id,
            "trigger": "manual",
            "data": {"Raw": data_array},
            "count": 1,
            "wait_for_completion": true
        });
        let trigger_body_str =
            serde_json::to_string(&trigger_body).map_err(|e| format!("serialize trigger body: {}", e))?;

        // POST to /dev/triggers to fire chain-responder
        let trigger_url = format!("{}/dev/triggers", wavs_node_url.trim_end_matches('/'));
        host::log(LogLevel::Info, &format!("chain-caller: POST {}", trigger_url));

        let _post_resp = http::post(&trigger_url, trigger_body_str.as_bytes(), "application/json")
            .map_err(|e| format!("POST trigger: {}", e))?;

        host::log(LogLevel::Info, "chain-caller: trigger fired, reading KV output");

        // GET the KV result that chain-responder stored
        let kv_url = format!(
            "{}/dev/kv/{}/chain/output",
            wavs_node_url.trim_end_matches('/'),
            callee_service_id
        );
        host::log(LogLevel::Info, &format!("chain-caller: GET {}", kv_url));

        let kv_bytes = http::get(&kv_url).map_err(|e| format!("GET kv: {}", e))?;

        let callee_output_hex = hex_encode(&kv_bytes);
        let callee_output_utf8 = String::from_utf8(kv_bytes)
            .unwrap_or_else(|_| "not utf8".to_string());

        let output = serde_json::json!({
            "caller_input": caller_input,
            "callee_output_hex": callee_output_hex,
            "callee_output_utf8": callee_output_utf8
        });
        let output_bytes = serde_json::to_vec(&output).map_err(|e| e.to_string())?;

        let response = match dest {
            Destination::Ethereum => encode_trigger_output(trigger_id, &output_bytes),
            Destination::CliOutput => {
                WasmResponse { payload: output_bytes.into(), ordering: None, event_id_salt: None }
            }
        };

        Ok(vec![response])
    }
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}
