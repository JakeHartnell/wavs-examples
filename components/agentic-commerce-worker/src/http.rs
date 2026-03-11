/// Synchronous HTTP GET and POST using raw WASI poll primitives.
///
/// `fut.subscribe().block()` is the WASI equivalent of block_on — it
/// synchronously polls the future until the response arrives, using the
/// same WASI poll mechanism that wstd's block_on uses internally.
///
/// We implement this directly instead of via wstd because wstd's async
/// runtime pulls in `wasi:random@0.2.9` which the WAVS operator world
/// does not provide.
use crate::bindings::wasi::http::outgoing_handler;
use crate::bindings::wasi::http::types::{
    Fields, IncomingBody, Method, OutgoingBody, OutgoingRequest, Scheme,
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
    send_request(req)
}

pub fn post_json(url: &str, body_bytes: &[u8]) -> Result<Vec<u8>, String> {
    let (scheme, authority, path_query) = parse_url(url)?;
    let headers = Fields::new();
    headers.append(&"content-type".to_string(), &b"application/json".to_vec())
        .map_err(|e| format!("set content-type: {:?}", e))?;
    headers.append(&"content-length".to_string(), &body_bytes.len().to_string().into_bytes())
        .map_err(|e| format!("set content-length: {:?}", e))?;

    let req = OutgoingRequest::new(headers);
    req.set_method(&Method::Post).map_err(|_| "set method POST")?;
    req.set_scheme(Some(&scheme)).map_err(|_| "set scheme")?;
    req.set_authority(Some(&authority)).map_err(|_| "set authority")?;
    req.set_path_with_query(Some(&path_query)).map_err(|_| "set path")?;

    {
        let outgoing_body = req.body().map_err(|_| "get outgoing body")?;
        let stream = outgoing_body.write().map_err(|_| "get write stream")?;
        stream.blocking_write_and_flush(body_bytes)
            .map_err(|e| format!("write body: {:?}", e))?;
        drop(stream);
        OutgoingBody::finish(outgoing_body, None)
            .map_err(|e| format!("finish body: {:?}", e))?;
    }

    send_request(req)
}

/// Publish plain-text content to paste.rs and return the paste URL.
/// Uses PUT https://paste.rs/ with raw text body — returns a plain-text URL.
pub fn publish_paste(content: &str) -> Result<String, String> {
    let body_bytes = content.as_bytes();
    let (scheme, authority, path_query) = parse_url("https://paste.rs/")?;
    let headers = Fields::new();
    headers.append(&"content-type".to_string(), &b"text/plain".to_vec())
        .map_err(|e| format!("set content-type: {:?}", e))?;
    headers.append(&"content-length".to_string(), &body_bytes.len().to_string().into_bytes())
        .map_err(|e| format!("set content-length: {:?}", e))?;

    let req = OutgoingRequest::new(headers);
    req.set_method(&Method::Put).map_err(|_| "set method PUT")?;
    req.set_scheme(Some(&scheme)).map_err(|_| "set scheme")?;
    req.set_authority(Some(&authority)).map_err(|_| "set authority")?;
    req.set_path_with_query(Some(&path_query)).map_err(|_| "set path")?;

    {
        let outgoing_body = req.body().map_err(|_| "get outgoing body")?;
        let stream = outgoing_body.write().map_err(|_| "get write stream")?;
        stream.blocking_write_and_flush(body_bytes)
            .map_err(|e| format!("write body: {:?}", e))?;
        drop(stream);
        OutgoingBody::finish(outgoing_body, None)
            .map_err(|e| format!("finish body: {:?}", e))?;
    }

    let response_bytes = send_request(req)?;
    let url = String::from_utf8(response_bytes)
        .map_err(|e| format!("paste.rs response not UTF-8: {}", e))?
        .trim()
        .to_string();

    if url.is_empty() || !url.starts_with("http") {
        return Err(format!("paste.rs returned unexpected response: {:?}", url));
    }

    Ok(url)
}

fn send_request(req: OutgoingRequest) -> Result<Vec<u8>, String> {
    let fut = outgoing_handler::handle(req, None)
        .map_err(|e| format!("HTTP request failed: {:?}", e))?;

    // Block synchronously using WASI poll — equivalent to block_on
    fut.subscribe().block();

    let resp = fut.get()
        .ok_or("future not ready after block")?
        .map_err(|_| "response future error")?
        .map_err(|e| format!("HTTP error: {:?}", e))?;

    let status = resp.status();
    if status < 200 || status >= 300 {
        return Err(format!("HTTP {}", status));
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
                if empty_reads > 32 { break; }
            }
            Ok(chunk) => { bytes.extend_from_slice(&chunk); empty_reads = 0; }
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
    let (scheme, rest) = if let Some(s) = url.strip_prefix("https://") {
        (Scheme::Https, s)
    } else if let Some(s) = url.strip_prefix("http://") {
        (Scheme::Http, s)
    } else {
        return Err(format!("unsupported URL scheme: {}", url));
    };
    let (authority, path_query) = match rest.find('/') {
        Some(pos) => (rest[..pos].to_string(), rest[pos..].to_string()),
        None => (rest.to_string(), "/".to_string()),
    };
    Ok((scheme, authority, path_query))
}
