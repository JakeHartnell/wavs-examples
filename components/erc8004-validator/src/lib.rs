#[rustfmt::skip]
pub mod bindings;
mod trigger;

use crate::bindings::{export, Guest, TriggerAction, WasmResponse};
use alloy_primitives::keccak256;
use anyhow::Result;
use trigger::{decode_trigger_event, encode_validation_output, Destination};

struct Component;
export!(Component with_types_in bindings);

/// Synchronous HTTP GET using raw WASI bindings.
///
/// wstd 0.5.6 imports wasi:random@0.2.9 (incompatible with the WAVS node which
/// supports up to @0.2.3). By using the raw WASI HTTP bindings from our WIT
/// directly, cargo-component adapts them to @0.2.3. No async, no Reactor, no
/// HashMap, no wasi:random at all.
mod http {
    use crate::bindings::wasi::http::outgoing_handler;
    use crate::bindings::wasi::http::types::{
        Fields, IncomingBody, Method, OutgoingRequest, Scheme,
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

    fn parse_url(url: &str) -> Result<(Scheme, String, String), String> {
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
        let trigger = decode_trigger_event(action.data).map_err(|e| e.to_string())?;

        // Fetch the content at the request URI
        let content = http::get(&trigger.request_uri)
            .map_err(|e| format!("fetch[{}]: {}", trigger.request_uri, e))?;

        // Compute keccak256 of the fetched bytes
        // The submit contract compares this against the stored requestHash on-chain
        let computed_hash = keccak256(&content);

        let output = match trigger.dest {
            Destination::Ethereum => {
                vec![encode_validation_output(trigger.trigger_id, computed_hash.into())]
            }
            Destination::CliOutput => {
                // For CLI testing: return a JSON summary
                let summary = format!(
                    r#"{{"trigger_id":{},"request_uri":"{}","computed_hash":"0x{}"}}"#,
                    trigger.trigger_id,
                    trigger.request_uri,
                    hex::encode(computed_hash.as_slice()),
                );
                vec![WasmResponse {
                    payload: summary.into_bytes(),
                    ordering: None,
                    event_id_salt: None,
                }]
            }
        };

        Ok(output)
    }
}
