//! crypto-price — WAVS tool component
//!
//! Accepts either:
//!   - JSON tool args:  {"symbol": "BTC"}   (from llm-agent)
//!   - Plain string:    "BTC"               (direct trigger)
//!
//! Fetches current price from CoinMarketCap data API (no API key required).
//! Writes result to KV store (bucket="tool", key="result") for tool-protocol compatibility.
//! Returns JSON: {"symbol":"BTC","price_usd":83920.0,"timestamp":"2026-03-13T11:54:00"}

#[rustfmt::skip]
pub mod bindings;
mod trigger;

use crate::bindings::wavs::types::core::LogLevel;
use crate::bindings::wasi::keyvalue::store;
use crate::bindings::{export, host, Guest, TriggerAction, WasmResponse};
use serde::{Deserialize, Serialize};
use trigger::{decode_trigger_event, encode_trigger_output};

struct Component;
export!(Component with_types_in bindings);

// ── Output type ───────────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
struct PriceData {
    symbol: String,
    price_usd: f64,
    timestamp: String,
}

// ── CoinMarketCap internal API response types ─────────────────────────────────

#[derive(Deserialize)]
struct CmcRoot {
    data: CmcData,
    status: CmcStatus,
}

#[derive(Deserialize)]
struct CmcData {
    symbol: String,
    statistics: CmcStatistics,
}

#[derive(Deserialize)]
struct CmcStatistics {
    price: f64,
}

#[derive(Deserialize)]
struct CmcStatus {
    timestamp: String,
}

// ── Component impl ────────────────────────────────────────────────────────────

impl Guest for Component {
    fn run(action: TriggerAction) -> Result<Vec<WasmResponse>, String> {
        let (trigger_id, data_bytes, _dest) =
            decode_trigger_event(action.data).map_err(|e| e.to_string())?;

        // Parse symbol from args — supports JSON {"symbol":"BTC"} or plain "BTC"
        let symbol = parse_symbol(&data_bytes)?;
        let symbol = symbol.to_uppercase();

        host::log(LogLevel::Info, &format!("crypto-price: fetching price for {}", symbol));

        let cmc_id = symbol_to_cmc_id(&symbol)
            .ok_or_else(|| format!("unknown symbol: {} (supported: BTC, ETH, SOL, AVAX, MATIC, LINK, UNI, DOGE, ADA, DOT)", symbol))?;

        let price_data = fetch_price(cmc_id, &symbol)?;

        host::log(
            LogLevel::Info,
            &format!("crypto-price: {} = ${:.2}", price_data.symbol, price_data.price_usd),
        );

        let res = serde_json::to_vec(&price_data)
            .map_err(|e| format!("serialize: {e}"))?;

        // ── Write to KV for tool-protocol ─────────────────────────────────────
        let bucket = store::open("tool")
            .map_err(|e| format!("open kv bucket 'tool': {:?}", e))?;
        bucket.set("result", &res)
            .map_err(|e| format!("kv set 'result': {:?}", e))?;

        host::log(LogLevel::Info, "crypto-price: wrote result to KV tool/result");

        // Always ABI-encode as DataWithId so on-chain submissions via SimpleSubmit succeed.
        // This includes tool-protocol calls (TriggerData::Raw) which get trigger_id=0.
        Ok(vec![encode_trigger_output(trigger_id, &res)])
    }
}

// ── Input parsing ─────────────────────────────────────────────────────────────

/// Accepts either `{"symbol":"BTC"}` JSON bytes or raw UTF-8 string "BTC".
fn parse_symbol(data: &[u8]) -> Result<String, String> {
    // Try JSON first
    if let Ok(v) = serde_json::from_slice::<serde_json::Value>(data) {
        if let Some(sym) = v.get("symbol").and_then(|s| s.as_str()) {
            return Ok(sym.to_string());
        }
    }
    // Fall back to plain string
    String::from_utf8(data.to_vec())
        .map(|s| s.trim().to_string())
        .map_err(|e| format!("UTF-8 decode: {e}"))
}

// ── Symbol → CoinMarketCap numeric ID mapping ────────────────────────────────

fn symbol_to_cmc_id(symbol: &str) -> Option<u64> {
    match symbol {
        "BTC"        => Some(1),
        "ETH"        => Some(1027),
        "SOL"        => Some(5426),
        "BNB"        => Some(1839),
        "XRP"        => Some(52),
        "ADA"        => Some(2010),
        "AVAX"       => Some(5805),
        "DOGE"       => Some(74),
        "DOT"        => Some(6636),
        "MATIC"|"POL"=> Some(3890),
        "LINK"       => Some(1975),
        "UNI"        => Some(7083),
        "ATOM"       => Some(3794),
        "NEAR"       => Some(6535),
        "ARB"        => Some(11841),
        "OP"         => Some(11840),
        "INJ"        => Some(7226),
        _            => None,
    }
}

// ── CoinMarketCap data API call ───────────────────────────────────────────────
// Uses the same undocumented data API as evm-price-oracle.
// Requires User-Agent + random Cookie to avoid 403.

fn fetch_price(cmc_id: u64, symbol: &str) -> Result<PriceData, String> {
    let url = format!(
        "https://api.coinmarketcap.com/data-api/v3/cryptocurrency/detail?id={}&range=1h",
        cmc_id
    );

    // Spoof a browser request — same technique as evm-price-oracle
    let headers = vec![
        ("User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36".to_string()),
        ("Accept", "application/json".to_string()),
        ("Cookie", format!("myrandom_cookie={}", cmc_id * 1000 + 42)),
    ];

    let resp: CmcRoot = http::get_json_with_headers(&url, &headers)?;
    let price = (resp.data.statistics.price * 100.0).round() / 100.0;
    let timestamp = resp.status.timestamp.split('.').next().unwrap_or("").to_string();

    Ok(PriceData {
        symbol: resp.data.symbol,
        price_usd: price,
        timestamp,
    })
}

// ── HTTP helpers (raw WASI) ───────────────────────────────────────────────────

mod http {
    use crate::bindings::wasi::http::outgoing_handler;
    use crate::bindings::wasi::http::types::{
        Fields, IncomingBody, Method, OutgoingRequest, Scheme,
    };
    use crate::bindings::wasi::io::streams::StreamError;

    pub fn get_json<T: serde::de::DeserializeOwned>(url: &str) -> Result<T, String> {
        let bytes = get_with_headers(url, &[])?;
        serde_json::from_slice(&bytes).map_err(|e| format!("JSON parse: {e}"))
    }

    pub fn get_json_with_headers<T: serde::de::DeserializeOwned>(
        url: &str,
        headers: &[(&str, String)],
    ) -> Result<T, String> {
        let bytes = get_with_headers(url, headers)?;
        serde_json::from_slice(&bytes).map_err(|e| format!("JSON parse: {e}"))
    }

    pub fn get_with_headers(url: &str, extra_headers: &[(&str, String)]) -> Result<Vec<u8>, String> {
        let (scheme, authority, path_query) = parse_url(url)?;

        let headers = Fields::new();
        for (name, value) in extra_headers {
            headers.append(
                &name.to_string(),
                &value.as_bytes().to_vec(),
            ).map_err(|e| format!("set header {}: {:?}", name, e))?;
        }
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
            .ok_or("future not ready")?
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
        drop(stream);
        // NOTE: do NOT call IncomingBody::finish() — resource has children panic
        drop(body);
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
