#[rustfmt::skip]
pub mod bindings;
pub mod solidity;
mod trigger;

use crate::bindings::{export, Guest, TriggerAction, WasmResponse};
use alloy_sol_types::SolValue;
use anyhow::Result;
use serde::{Deserialize, Serialize};
use trigger::{decode_trigger_event, encode_trigger_output, Destination};
use wavs_wasi_utils::http::{fetch_json, http_request_get};
use wstd::{http::HeaderValue, runtime::block_on};

struct Component;
export!(Component with_types_in bindings);

/// Input: ABI-encoded string, either a city name ("London") or
/// "lat,lon" coordinates ("51.5074,-0.1278").
impl Guest for Component {
    fn run(action: TriggerAction) -> Result<Vec<WasmResponse>, String> {
        let (trigger_id, req, dest) =
            decode_trigger_event(action.data).map_err(|e| e.to_string())?;

        let hex_data = match String::from_utf8(req.clone()) {
            Ok(s) if s.starts_with("0x") => {
                wavs_wasi_utils::evm::alloy_primitives::hex::decode(&s[2..])
                    .map_err(|e| format!("hex decode: {}", e))?
            }
            _ => req.clone(),
        };

        let location = <String as SolValue>::abi_decode(&hex_data)
            .map_err(|e| format!("ABI decode: {}", e))?;

        let res = block_on(async move {
            let data = get_weather(&location).await?;
            serde_json::to_vec(&data).map_err(|e| e.to_string())
        })?;

        let output = match dest {
            Destination::Ethereum => vec![encode_trigger_output(trigger_id, &res)],
            Destination::CliOutput => {
                vec![WasmResponse { payload: res.into(), ordering: None, event_id_salt: None }]
            }
        };
        Ok(output)
    }
}

/// Resolve location → (lat, lon) then fetch current weather from Open-Meteo.
/// Supports:
///   - "lat,lon"  e.g. "40.7128,-74.0060"
///   - city name  e.g. "Tokyo" (geocoded via Open-Meteo geocoding API)
async fn get_weather(location: &str) -> Result<WeatherData, String> {
    let (lat, lon, location_name) = resolve_location(location).await?;
    fetch_weather(lat, lon, location_name).await
}

async fn resolve_location(location: &str) -> Result<(f64, f64, String), String> {
    // Try parsing as "lat,lon"
    let parts: Vec<&str> = location.splitn(2, ',').collect();
    if parts.len() == 2 {
        if let (Ok(lat), Ok(lon)) = (parts[0].trim().parse::<f64>(), parts[1].trim().parse::<f64>()) {
            return Ok((lat, lon, location.to_string()));
        }
    }

    // Geocode via Open-Meteo geocoding API (no key required)
    let url = format!(
        "https://geocoding-api.open-meteo.com/v1/search?name={}&count=1&language=en&format=json",
        urlencode(location)
    );
    let req = http_request_get(&url).map_err(|e| e.to_string())?;
    let geo: GeoResponse = fetch_json(req).await.map_err(|e| e.to_string())?;

    let result = geo
        .results
        .and_then(|r| r.into_iter().next())
        .ok_or_else(|| format!("Location not found: {}", location))?;

    Ok((result.latitude, result.longitude, result.name))
}

async fn fetch_weather(lat: f64, lon: f64, location_name: String) -> Result<WeatherData, String> {
    let url = format!(
        "https://api.open-meteo.com/v1/forecast?\
         latitude={}&longitude={}\
         &current=temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code\
         &temperature_unit=celsius&wind_speed_unit=kmh&format=json",
        lat, lon
    );

    let mut req = http_request_get(&url).map_err(|e| e.to_string())?;
    req.headers_mut().insert("Accept", HeaderValue::from_static("application/json"));

    let resp: OpenMeteoResponse = fetch_json(req).await.map_err(|e| e.to_string())?;
    let c = resp.current;

    Ok(WeatherData {
        location: location_name,
        latitude: lat,
        longitude: lon,
        temperature_c: c.temperature_2m,
        humidity_pct: c.relative_humidity_2m,
        wind_speed_kmh: c.wind_speed_10m,
        weather_code: c.weather_code,
        description: weather_code_description(c.weather_code),
        timestamp: resp.current_units.time.unwrap_or_default(),
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

/// WMO weather code → human description
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

// ── Output type ──────────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
pub struct WeatherData {
    pub location: String,
    pub latitude: f64,
    pub longitude: f64,
    pub temperature_c: f64,
    pub humidity_pct: u64,
    pub wind_speed_kmh: f64,
    pub weather_code: u64,
    pub description: &'static str,
    pub timestamp: String,
}

// ── Open-Meteo API types ─────────────────────────────────────────────────────

#[derive(Deserialize)]
struct OpenMeteoResponse {
    current: CurrentWeather,
    current_units: CurrentUnits,
}

#[derive(Deserialize)]
struct CurrentWeather {
    temperature_2m: f64,
    relative_humidity_2m: u64,
    wind_speed_10m: f64,
    weather_code: u64,
}

#[derive(Deserialize)]
struct CurrentUnits {
    time: Option<String>,
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
