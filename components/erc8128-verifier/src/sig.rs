/// RFC 9421 + ERC-8128 signature parsing and verification.
///
/// ERC-8128 uses HTTP Message Signatures (RFC 9421) with EIP-191 (`personal_sign`)
/// as the signing algorithm. This module:
///   - Parses `Signature-Input` and `Signature` headers
///   - Reconstructs the RFC 9421 signature base
///   - Applies the ERC-191 prefix to produce the hash
///   - Recovers the Ethereum address via secp256k1 ecrecover
use alloy_primitives::{keccak256, Address, B256};
use anyhow::{Context, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use k256::ecdsa::{RecoveryId, Signature as EcdsaSig, VerifyingKey};
use std::collections::HashMap;

/// Parsed result from a `Signature-Input` header for a single label.
pub struct ParsedSigInput {
    /// Covered component identifiers in order (e.g. ["@method", "@authority", "@path"])
    pub components: Vec<String>,
    /// Full expression after `label=` in the header (used verbatim as the
    /// `@signature-params` line in the signature base).
    pub sig_params_value: String,
    /// The `keyid` parameter value — format: `eip8128:<chain-id>:<address>`
    pub keyid: String,
    /// `created` Unix timestamp (seconds)
    pub created: i64,
    /// `expires` Unix timestamp (seconds)
    pub expires: i64,
    /// Optional `nonce` for replay protection
    pub nonce: Option<String>,
}

/// Parsed ERC-8128 `keyid`
pub struct ParsedKeyid {
    pub chain_id: u64,
    /// Lowercase `0x`-prefixed address string
    pub address: String,
}

// ─── Header field parsers ────────────────────────────────────────────────────

/// Extract a quoted-string parameter: `name="value"` → `value`
fn extract_param_str(params: &str, name: &str) -> Result<String> {
    let needle = format!("{}=\"", name);
    let start = params
        .find(&needle)
        .ok_or_else(|| anyhow::anyhow!("param '{}' not found", name))?;
    let after = &params[start + needle.len()..];
    let end = after
        .find('"')
        .ok_or_else(|| anyhow::anyhow!("unclosed string for param '{}'", name))?;
    Ok(after[..end].to_string())
}

/// Extract an integer parameter: `name=12345` → `12345`
fn extract_param_int(params: &str, name: &str) -> Result<i64> {
    let needle = format!("{}=", name);
    let start = params
        .find(&needle)
        .ok_or_else(|| anyhow::anyhow!("param '{}' not found", name))?;
    let after = &params[start + needle.len()..];
    let end = after
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(after.len());
    after[..end]
        .parse::<i64>()
        .context(format!("invalid integer for param '{}'", name))
}

// ─── Public API ──────────────────────────────────────────────────────────────

/// Parse the `Signature-Input` header value for the given `label`.
///
/// Header example:
/// ```text
/// eth=("@method" "@authority" "@path");keyid="eip8128:1:0x...";created=1618884475;expires=1618884775;nonce="abc123"
/// ```
pub fn parse_signature_input(header: &str, label: &str) -> Result<ParsedSigInput> {
    // Locate `label=(` within the header (handles multi-label headers)
    let prefix = format!("{}=(", label);
    let pos = header
        .find(&prefix)
        .ok_or_else(|| anyhow::anyhow!("label '{}' not found in Signature-Input", label))?;

    // sig_params_value = everything from `(` onward for this label
    // (stops naturally when Cargo serialises a single-label header)
    let sig_params_value = header[pos + label.len() + 1..].trim().to_string();

    // Parse component list inside ( ... )
    let paren_end = sig_params_value
        .find(')')
        .ok_or_else(|| anyhow::anyhow!("no closing ')' in Signature-Input for label '{}'", label))?;
    let components_str = &sig_params_value[1..paren_end];
    let components: Vec<String> = components_str
        .split_whitespace()
        .map(|s| s.trim_matches('"').to_string())
        .filter(|s| !s.is_empty())
        .collect();

    // Parameters follow the closing `)`
    let params_rest = &sig_params_value[paren_end + 1..];
    let keyid = extract_param_str(params_rest, "keyid").context("keyid")?;
    let created = extract_param_int(params_rest, "created").context("created")?;
    let expires = extract_param_int(params_rest, "expires").context("expires")?;
    let nonce = extract_param_str(params_rest, "nonce").ok();

    Ok(ParsedSigInput {
        components,
        sig_params_value,
        keyid,
        created,
        expires,
        nonce,
    })
}

/// Parse `keyid` string `eip8128:<chain-id>:<address>` into its parts.
pub fn parse_keyid(keyid: &str) -> Result<ParsedKeyid> {
    let parts: Vec<&str> = keyid.splitn(3, ':').collect();
    if parts.len() != 3 || parts[0] != "eip8128" {
        return Err(anyhow::anyhow!(
            "invalid keyid format (expected eip8128:<chain-id>:<addr>): {}",
            keyid
        ));
    }
    let chain_id = parts[1]
        .parse::<u64>()
        .context("chain_id in keyid is not a valid u64")?;
    let address = parts[2].to_lowercase();
    if !address.starts_with("0x") || address.len() != 42 {
        return Err(anyhow::anyhow!(
            "invalid address in keyid (expected 0x + 40 hex): {}",
            address
        ));
    }
    Ok(ParsedKeyid { chain_id, address })
}

/// Decode the raw signature bytes from a `Signature` header field.
///
/// Header format: `eth=:base64bytes:`
pub fn parse_signature_bytes(header: &str, label: &str) -> Result<Vec<u8>> {
    let prefix = format!("{}=:", label);
    let pos = header
        .find(&prefix)
        .ok_or_else(|| anyhow::anyhow!("label '{}' not found in Signature header", label))?;
    let after = &header[pos + prefix.len()..];
    let end = after
        .find(':')
        .ok_or_else(|| anyhow::anyhow!("no closing ':' in Signature header for label '{}'", label))?;
    BASE64.decode(&after[..end]).context("base64 decode of Signature bytes")
}

/// Reconstruct the RFC 9421 signature base from covered components and their values.
///
/// Format (RFC 9421 §2.5):
/// ```text
/// "<component-id>": <value>\n
/// ...
/// "@signature-params": <sig-params-value>
/// ```
/// The `@signature-params` line is always last. No trailing newline.
pub fn reconstruct_signature_base(
    parsed: &ParsedSigInput,
    component_values: &HashMap<String, String>,
) -> Result<String> {
    let mut lines: Vec<String> = Vec::with_capacity(parsed.components.len() + 1);

    for component in &parsed.components {
        let value = component_values
            .get(component)
            .ok_or_else(|| anyhow::anyhow!("missing value for covered component '{}'", component))?;
        // RFC 9421: `"<id>": <value>` — value is verbatim (already canonicalized by the signer)
        lines.push(format!(r#""{}": {}"#, component, value));
    }

    // Final line: @signature-params
    lines.push(format!(r#""@signature-params": {}"#, parsed.sig_params_value));

    Ok(lines.join("\n"))
}

/// Compute the ERC-191 `personal_sign` hash of a message:
///
/// ```text
/// keccak256("\x19Ethereum Signed Message:\n" + decimal(len(msg)) + msg)
/// ```
///
/// ERC-8128 §3.4.3 specifies this as the digest to sign over the RFC 9421
/// signature base.
pub fn erc191_hash(message: &[u8]) -> B256 {
    let prefix = format!("\x19Ethereum Signed Message:\n{}", message.len());
    let mut buf = Vec::with_capacity(prefix.len() + message.len());
    buf.extend_from_slice(prefix.as_bytes());
    buf.extend_from_slice(message);
    keccak256(&buf)
}

/// Recover the Ethereum signer address from a 65-byte secp256k1 signature
/// (`r[32] || s[32] || v[1]`) and a pre-computed hash.
///
/// `v` may be 27/28 (Ethereum convention) or 0/1 (raw). Both are handled.
pub fn ecrecover(sig_bytes: &[u8], prehash: &B256) -> Result<Address> {
    if sig_bytes.len() != 65 {
        return Err(anyhow::anyhow!(
            "signature must be 65 bytes, got {}",
            sig_bytes.len()
        ));
    }
    let v = sig_bytes[64];
    let recovery_id = if v >= 27 { v - 27 } else { v };
    if recovery_id > 1 {
        return Err(anyhow::anyhow!("invalid recovery id byte: {}", v));
    }

    let ecdsa_sig =
        EcdsaSig::from_slice(&sig_bytes[..64]).context("parse ecdsa signature (r||s)")?;
    let recid = RecoveryId::from_byte(recovery_id)
        .ok_or_else(|| anyhow::anyhow!("invalid recovery id: {}", recovery_id))?;

    let vk = VerifyingKey::recover_from_prehash(prehash.as_slice(), &ecdsa_sig, recid)
        .context("secp256k1 ecrecover")?;

    // SEC1 uncompressed: 0x04 || x[32] || y[32]
    let point = vk.to_encoded_point(/*compress=*/ false);
    let pub_key_bytes = point.as_bytes();
    debug_assert_eq!(pub_key_bytes[0], 0x04);

    let hash = keccak256(&pub_key_bytes[1..]);
    Ok(Address::from_slice(&hash[12..]))
}

// ─── Unit tests ──────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_signature_input() {
        let header = r#"eth=("@method" "@authority" "@path");keyid="eip8128:1:0xabcdef1234567890abcdef1234567890abcdef12";created=1618884475;expires=1618884775;nonce="abc123""#;
        let p = parse_signature_input(header, "eth").unwrap();
        assert_eq!(p.components, vec!["@method", "@authority", "@path"]);
        assert_eq!(
            p.keyid,
            "eip8128:1:0xabcdef1234567890abcdef1234567890abcdef12"
        );
        assert_eq!(p.created, 1618884475);
        assert_eq!(p.expires, 1618884775);
        assert_eq!(p.nonce, Some("abc123".to_string()));
    }

    #[test]
    fn test_parse_keyid() {
        let kd = parse_keyid("eip8128:1:0xAbCd123456789012345678901234567890AbCd12").unwrap();
        assert_eq!(kd.chain_id, 1);
        assert_eq!(kd.address, "0xabcd123456789012345678901234567890abcd12");
    }

    #[test]
    fn test_reconstruct_signature_base() {
        let header = r#"eth=("@method" "@authority" "@path");keyid="eip8128:1:0xabc0000000000000000000000000000000000001";created=1618884475;expires=1618884775;nonce="xyz""#;
        let parsed = parse_signature_input(header, "eth").unwrap();
        let mut values = HashMap::new();
        values.insert("@method".to_string(), "POST".to_string());
        values.insert("@authority".to_string(), "api.example.com".to_string());
        values.insert("@path".to_string(), "/orders".to_string());

        let base = reconstruct_signature_base(&parsed, &values).unwrap();
        let lines: Vec<&str> = base.split('\n').collect();
        assert_eq!(lines[0], r#""@method": POST"#);
        assert_eq!(lines[1], r#""@authority": api.example.com"#);
        assert_eq!(lines[2], r#""@path": /orders"#);
        assert!(lines[3].starts_with(r#""@signature-params": "#));
        // No trailing newline
        assert!(!base.ends_with('\n'));
    }

    #[test]
    fn test_parse_signature_header() {
        // RFC 9421 base64 format: label=:bytes:
        use base64::Engine as _;
        let raw = vec![0u8; 65];
        let b64 = BASE64.encode(&raw);
        let header = format!("eth=:{}:", b64);
        let decoded = parse_signature_bytes(&header, "eth").unwrap();
        assert_eq!(decoded, raw);
    }
}
