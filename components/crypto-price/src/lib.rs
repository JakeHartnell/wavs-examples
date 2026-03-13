//! crypto-price — WAVS tool component
//!
//! Accepts either:
//!   - JSON tool args:  {"symbol": "BTC"}   (from llm-agent)
//!   - Plain string:    "BTC"               (direct trigger)
//!
//! Fetches current price from CoinGecko (no API key required).
//! Writes result to KV store (bucket="tool", key="result") for tool-protocol compatibility.
//! Returns JSON: {"symbol":"BTC","price_usd":69885.0,"change_24h_pct":-1.2,"timestamp":"..."}

#[rustfmt::skip]
pub mod bindings;
mod trigger;

use crate::bindings::wavs::types::core::LogLevel;
use crate::bindings::wasi::keyvalue::store;
use crate::bindings::{export, host, Guest, TriggerAction, WasmResponse};
use serde::{Deserialize, Serialize};
use trigger::{decode_trigger_event, encode_trigger_output, Destination};

struct Component;
export!(Component with_types_in bindings);

// ── Output type ───────────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
struct PriceData {
    symbol: String,
    coingecko_id: String,
    price_usd: f64,
    change_24h_pct: f64,
    market_cap_usd: f64,
    timestamp_unix: u64,
}

// ── CoinGecko API response type ───────────────────────────────────────────────

#[derive(Deserialize)]
struct CoinGeckoMarket {
    symbol: String,
    current_price: f64,
    price_change_percentage_24h: Option<f64>,
    market_cap: Option<f64>,
    last_updated: String,
}

// ── Component impl ────────────────────────────────────────────────────────────

impl Guest for Component {
    fn run(action: TriggerAction) -> Result<Vec<WasmResponse>, String> {
        let (trigger_id, data_bytes, dest) =
            decode_trigger_event(action.data).map_err(|e| e.to_string())?;

        // Parse symbol from args — supports JSON {"symbol":"BTC"} or plain "BTC"
        let symbol = parse_symbol(&data_bytes)?;
        let symbol = symbol.to_uppercase();

        host::log(LogLevel::Info, &format!("crypto-price: fetching price for {}", symbol));

        let coingecko_id = symbol_to_coingecko_id(&symbol)
            .ok_or_else(|| format!("unknown symbol: {} (supported: BTC, ETH, SOL, AVAX, MATIC, LINK, UNI, DOGE)", symbol))?;

        let price_data = fetch_price(coingecko_id, &symbol)?;

        host::log(
            LogLevel::Info,
            &format!("crypto-price: {} = ${:.2} ({:+.2}% 24h)",
                price_data.symbol, price_data.price_usd, price_data.change_24h_pct),
        );

        let res = serde_json::to_vec(&price_data)
            .map_err(|e| format!("serialize: {e}"))?;

        // ── Write to KV for tool-protocol ─────────────────────────────────────
        let bucket = store::open("tool")
            .map_err(|e| format!("open kv bucket 'tool': {:?}", e))?;
        bucket.set("result", &res)
            .map_err(|e| format!("kv set 'result': {:?}", e))?;

        host::log(LogLevel::Info, "crypto-price: wrote result to KV tool/result");

        let output = match dest {
            Destination::Ethereum => vec![encode_trigger_output(trigger_id, &res)],
            Destination::CliOutput => {
                vec![WasmResponse { payload: res, ordering: None, event_id_salt: None }]
            }
        };
        Ok(output)
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

// ── Symbol → CoinGecko ID mapping ────────────────────────────────────────────

fn symbol_to_coingecko_id(symbol: &str) -> Option<&'static str> {
    match symbol {
        "BTC" => Some("bitcoin"),
        "ETH" => Some("ethereum"),
        "SOL" => Some("solana"),
        "AVAX" => Some("avalanche-2"),
        "MATIC" | "POL" => Some("matic-network"),
        "LINK" => Some("chainlink"),
        "UNI" => Some("uniswap"),
        "DOGE" => Some("dogecoin"),
        "ADA" => Some("cardano"),
        "DOT" => Some("polkadot"),
        "ATOM" => Some("cosmos"),
        "NEAR" => Some("near"),
        "ARB" => Some("arbitrum"),
        "OP" => Some("optimism"),
        "INJ" => Some("injective-protocol"),
        _ => None,
    }
}

// ── CoinGecko API call ────────────────────────────────────────────────────────

fn fetch_price(coingecko_id: &'static str, symbol: &str) -> Result<PriceData, String> {
    let url = format!(
        "https://api.coingecko.com/api/v3/coins/markets\
         ?vs_currency=usd\
         &ids={}\
         &order=market_cap_desc\
         &per_page=1\
         &page=1\
         &sparkline=false\
         &price_change_percentage=24h",
        coingecko_id
    );

    let markets: Vec<CoinGeckoMarket> = http::get_json(&url)?;
    let m = markets
        .into_iter()
        .next()
        .ok_or_else(|| format!("no data returned for {}", coingecko_id))?;

    // CoinGecko last_updated is ISO 8601, e.g. "2024-01-01T12:00:00.000Z"
    // We'll keep it as-is for readability
    let timestamp_unix = iso8601_to_unix(&m.last_updated).unwrap_or(0);

    Ok(PriceData {
        symbol: symbol.to_string(),
        coingecko_id: coingecko_id.to_string(),
        price_usd: (m.current_price * 100.0).round() / 100.0,
        change_24h_pct: (m.price_change_percentage_24h.unwrap_or(0.0) * 100.0).round() / 100.0,
        market_cap_usd: m.market_cap.unwrap_or(0.0),
        timestamp_unix,
    })
}

/// Minimal ISO 8601 UTC → Unix timestamp (no external deps, good enough for logging).
fn iso8601_to_unix(s: &str) -> Option<u64> {
    // Expected: "2024-01-15T12:34:56.000Z"
    let s = s.trim_end_matches('Z').trim_end_matches(|c: char| c == '.' || c.is_ascii_digit());
    let parts: Vec<&str> = s.splitn(2, 'T').collect();
    if parts.len() != 2 { return None; }
    let date_parts: Vec<u32> = parts[0].split('-').filter_map(|p| p.parse().ok()).collect();
    let time_parts: Vec<u32> = parts[1].split(':').filter_map(|p| p.parse().ok()).collect();
    if date_parts.len() < 3 || time_parts.len() < 3 { return None; }
    // Approximate days since epoch (ignore leap seconds etc.)
    let y = date_parts[0] as u64;
    let m = date_parts[1] as u64;
    let d = date_parts[2] as u64;
    let days = (y - 1970) * 365 + (y - 1969) / 4 + [0,31,59,90,120,151,181,212,243,273,304,334]
        .get((m - 1) as usize).copied().unwrap_or(0) + d - 1;
    Some(days * 86400 + time_parts[0] as u64 * 3600 + time_parts[1] as u64 * 60 + time_parts[2] as u64)
}

// ── HTTP helpers (raw WASI) ───────────────────────────────────────────────────

mod http {
    use crate::bindings::wasi::http::outgoing_handler;
    use crate::bindings::wasi::http::types::{
        Fields, IncomingBody, Method, OutgoingRequest, Scheme,
    };
    use crate::bindings::wasi::io::streams::StreamError;

    pub fn get_json<T: serde::de::DeserializeOwned>(url: &str) -> Result<T, String> {
        let bytes = get(url)?;
        serde_json::from_slice(&bytes).map_err(|e| format!("JSON parse: {e}"))
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
