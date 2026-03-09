//! ERC-8128 Verifier — WAVS Component (PoC)
//!
//! Receives an HTTP request payload via a raw WAVS trigger, reconstructs the
//! RFC 9421 signature base, applies the ERC-191 `personal_sign` digest, and
//! recovers the Ethereum signer address via secp256k1 ecrecover.
//!
//! No on-chain submission: the recovered address is returned in the
//! `WasmResponse` payload as JSON and is visible in the WAVS node logs.
//!
//! # Input (raw trigger JSON)
//! ```json
//! {
//!   "signature_input": "eth=(\"@method\" \"@authority\" \"@path\");keyid=\"eip8128:1:0xdeadbeef...\";created=1618884475;expires=1618884775;nonce=\"abc123\"",
//!   "signature": "eth=:base64-encoded-65-byte-sig:",
//!   "components": {
//!     "@method": "POST",
//!     "@authority": "api.example.com",
//!     "@path": "/orders"
//!   }
//! }
//! ```
//!
//! # Output (WasmResponse JSON)
//! ```json
//! {
//!   "valid": true,
//!   "recovered_address": "0xdeadbeef...",
//!   "expected_address": "0xdeadbeef...",
//!   "chain_id": 1,
//!   "keyid": "eip8128:1:0xdeadbeef...",
//!   "note": "✅ signature valid: address recovered"
//! }
//! ```

#[rustfmt::skip]
pub mod bindings;
mod sig;
mod trigger;

use crate::bindings::{export, Guest, TriggerAction, WasmResponse};
use crate::sig::{
    erc191_hash, ecrecover, parse_keyid, parse_signature_bytes, parse_signature_input,
    reconstruct_signature_base,
};
use crate::trigger::decode_trigger_event;
use anyhow::Result;

struct Component;
export!(Component with_types_in bindings);

impl Guest for Component {
    fn run(action: TriggerAction) -> Result<Vec<WasmResponse>, String> {
        run_inner(action).map_err(|e| format!("erc8128-verifier: {:#}", e))
    }
}

fn run_inner(action: TriggerAction) -> Result<Vec<WasmResponse>> {
    // 1. Decode trigger input (JSON)
    let input = decode_trigger_event(action.data)?;

    // 2. Parse Signature-Input header
    let parsed = parse_signature_input(&input.signature_input, &input.label)?;

    // 3. Parse keyid → expected chain_id + address
    let keyid = parse_keyid(&parsed.keyid)?;

    // 4. Reconstruct the RFC 9421 signature base from covered components
    let sig_base = reconstruct_signature_base(&parsed, &input.components)?;

    // 5. Apply ERC-191 prefix and hash
    //    ERC-8128 §3.4.3: H = keccak256("\x19Ethereum Signed Message:\n" || len(M) || M)
    let msg_hash = erc191_hash(sig_base.as_bytes());

    // 6. Decode signature bytes (base64 in RFC 9421 header format)
    let sig_bytes = parse_signature_bytes(&input.signature, &input.label)?;

    // 7. Recover Ethereum address via secp256k1 ecrecover
    let recovered = ecrecover(&sig_bytes, &msg_hash)?;
    let recovered_str = format!("{:#x}", recovered);

    // 8. Validate against keyid
    let addresses_match = recovered_str.to_lowercase() == keyid.address.to_lowercase();

    let note = if addresses_match {
        "✅ signature valid: address recovered"
    } else {
        "❌ address mismatch: signature may be invalid or keyid incorrect"
    };

    let result = serde_json::json!({
        "valid": addresses_match,
        "recovered_address": recovered_str,
        "expected_address": keyid.address,
        "chain_id": keyid.chain_id,
        "keyid": parsed.keyid,
        "created": parsed.created,
        "expires": parsed.expires,
        "nonce": parsed.nonce,
        "covered_components": parsed.components,
        "signature_base": sig_base,
        "msg_hash": format!("0x{}", hex::encode(msg_hash.as_slice())),
        "note": note
    });

    Ok(vec![WasmResponse {
        payload: serde_json::to_vec(&result)?,
        ordering: None,
        event_id_salt: None,
    }])
}
