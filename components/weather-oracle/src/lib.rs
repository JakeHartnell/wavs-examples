#[rustfmt::skip]
pub mod bindings;
pub mod solidity;
mod trigger;

use crate::bindings::{export, Guest, TriggerAction, WasmResponse};
use alloy_sol_types::SolValue;
use anyhow::Result;
use serde::{Deserialize, Serialize};
use trigger::{decode_trigger_event, encode_trigger_output, Destination};

struct Component;
export!(Component with_types_in bindings);

/// Synchronous HTTP GET using raw WASI bindings.
///
/// wstd 0.5.6 imports WASI @0.2.9 (too new for the WAVS node which supports up to @0.2.3).
/// By using the raw WASI HTTP bindings from our WIT directly, cargo-component adapts them
/// to @0.2.3 — compatible with the WAVS node.  No async executor, no Reactor, no HashMap,
/// no wasi:random needed at all.
mod http {
    use crate::bindings::wasi::http::outgoing_handler;
    use crate::bindings::wasi::http::types::{
        Fields, IncomingBody, Method, OutgoingRequest, Scheme,
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
            .map_err(|e| format!("HTTP request failed: {:?}", e))?;

        // Block synchronously until the response arrives
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
                        break; // safety valve
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
        let (trigger_id, req, dest) =
            decode_trigger_event(action.data).map_err(|e| e.to_string())?;

        // Trigger data is either:
        // - ABI-encoded string bytes (local testing: wavs-cli binary-decodes the --input hex)
        // - Raw UTF-8 bytes of the location string (on-chain: Solidity `bytes(_data)`)
        let location = if let Ok(s) = <String as SolValue>::abi_decode(&req) {
            s
        } else {
            String::from_utf8(req.clone()).map_err(|e| format!("UTF-8 decode: {}", e))?
        };

        let data = get_weather(&location)
            .map_err(|e| format!("weather[{}]: {}", location, e))?;
        let res = serde_json::to_vec(&data)
            .map_err(|e| format!("serialize: {}", e))?;

        let output = match dest {
            Destination::Ethereum => vec![encode_trigger_output(trigger_id, &res)],
            Destination::CliOutput => {
                vec![WasmResponse { payload: res.into(), ordering: None, event_id_salt: None }]
            }
        };
        Ok(output)
    }
}

fn get_weather(location: &str) -> Result<WeatherData, String> {
    let (lat, lon, name) = resolve_location(location)?;
    fetch_weather(lat, lon, name)
}

fn resolve_location(location: &str) -> Result<(f64, f64, String), String> {
    // Try "lat,lon" first
    if let Some(comma) = location.find(',') {
        let (a, b) = (&location[..comma], &location[comma + 1..]);
        if let (Ok(lat), Ok(lon)) = (a.trim().parse::<f64>(), b.trim().parse::<f64>()) {
            return Ok((lat, lon, location.to_string()));
        }
    }

    // Geocode via Open-Meteo
    let url = format!(
        "https://geocoding-api.open-meteo.com/v1/search?name={}&count=1&language=en&format=json",
        urlencode(location)
    );
    let geo: GeoResponse =
        http::get_json(&url).map_err(|e| format!("geocode({}): {}", location, e))?;

    geo.results
        .and_then(|r| r.into_iter().next())
        .map(|r| (r.latitude, r.longitude, r.name))
        .ok_or_else(|| format!("location not found: {}", location))
}

fn fetch_weather(lat: f64, lon: f64, name: String) -> Result<WeatherData, String> {
    let url = format!(
        "https://api.open-meteo.com/v1/forecast?\
         latitude={}&longitude={}\
         &current=temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code\
         &temperature_unit=celsius&wind_speed_unit=kmh&format=json",
        lat, lon
    );

    let resp: OpenMeteoResponse =
        http::get_json(&url).map_err(|e| format!("forecast: {}", e))?;
    let c = resp.current;

    Ok(WeatherData {
        location: name,
        latitude: lat,
        longitude: lon,
        temperature_c: c.temperature_2m,
        humidity_pct: c.relative_humidity_2m,
        wind_speed_kmh: c.wind_speed_10m,
        weather_code: c.weather_code,
        description: weather_code_description(c.weather_code).to_string(),
        timestamp: c.time,
    })
}

fn urlencode(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            'A'..='Z' | 'a'..='z' | '0'..='9' | '-' | '_' | '.' | '~' => c.to_string(),
            ' ' => "+".to_string(),
            c => format!("%{:02X}", c as u32),
        })
        .collect()
}

fn weather_code_description(code: u64) -> &'static str {
    match code {
        0 => "Clear sky",
        1 => "Mainly clear",
        2 => "Partly cloudy",
        3 => "Overcast",
        45 | 48 => "Fog",
        51 | 53 | 55 => "Drizzle",
        61 | 63 | 65 => "Rain",
        71 | 73 | 75 => "Snow",
        80 | 81 | 82 => "Rain showers",
        85 | 86 => "Snow showers",
        95 => "Thunderstorm",
        96 | 99 => "Thunderstorm with hail",
        _ => "Unknown",
    }
}

// ── Output ───────────────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
pub struct WeatherData {
    pub location: String,
    pub latitude: f64,
    pub longitude: f64,
    pub temperature_c: f64,
    pub humidity_pct: u64,
    pub wind_speed_kmh: f64,
    pub weather_code: u64,
    pub description: String,
    pub timestamp: String,
}

// ── Open-Meteo API types ─────────────────────────────────────────────────────

#[derive(Deserialize)]
struct OpenMeteoResponse {
    current: CurrentWeather,
}

#[derive(Deserialize)]
struct CurrentWeather {
    time: String,
    temperature_2m: f64,
    relative_humidity_2m: u64,
    wind_speed_10m: f64,
    weather_code: u64,
}

// ── Geocoding API types ──────────────────────────────────────────────────────

#[derive(Deserialize)]
struct GeoResponse {
    results: Option<Vec<GeoResult>>,
}

#[derive(Deserialize)]
struct GeoResult {
    name: String,
    latitude: f64,
    longitude: f64,
}
