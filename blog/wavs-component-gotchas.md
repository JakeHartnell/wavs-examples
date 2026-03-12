# Six Things That Will Break Your WAVS Component (And How to Fix Them)

*A field guide from building ERC-8183 Agentic Commerce on WAVS.*

---

Building with WAVS is powerful once you understand its WASM runtime. But there are a handful of gotchas that will waste hours if you don't know about them. We hit all six of these while building the ERC-8183 Agentic Commerce example — a system where WAVS acts as the trusted evaluator in an on-chain job escrow, watching `JobSubmitted` events, verifying deliverables, and calling `complete()` or `reject()` on a live contract.

Here's everything that bit us, how to diagnose it, and how to fix it.

---

## 1. `wstd` silently breaks your component

This one cost the most time. If you use `wstd` (or `wavs-wasi-utils`) in an **operator component**, your component will silently fail to instantiate. WAVS will simply drop every trigger. No error in logs. Nothing on-chain. Just silence.

**Why it happens:**

`wstd`'s async runtime imports `wasi:random/random@0.2.9`. The WAVS operator world doesn't provide `wasi:random` at all. The component fails to link, WAVS swallows the error, and your service appears healthy while doing nothing.

**Diagnosis:**

```bash
wasm-tools component wit your_component.wasm | grep "wasi:random"
```

If you see `import wasi:random/random@0.2.9`, your component will silently fail in the operator node.

**The fix — raw WASI polling:**

`wstd::block_on` is a thin wrapper around the WASI poll primitive. You can do exactly the same thing without the dependency:

```rust
// Instead of: wstd::runtime::block_on(async { ... })
// Do this:
let fut = outgoing_handler::handle(req, None)?;
fut.subscribe().block();  // ← this IS block_on, without wstd
let resp = fut.get().ok_or("not ready")??;
```

`subscribe().block()` synchronously polls the WASI future until the response arrives — the exact same mechanism `block_on` uses internally. No async runtime, no `wasi:random`, no problem.

**The catch about evm-price-oracle:**

The `evm-price-oracle` example in wavs-examples uses `wstd` and appears to work. It does — but only because the compiled binary in the repo was built with an older version that happened to produce compatible imports. If you rebuild it fresh today, it generates `@0.2.9` imports and will silently fail on the current node. Use it as a structural reference, not a copy-paste template for HTTP handling.

---

## 2. `println!` panics at runtime

No stdout in the WASM component model. If you have any `println!` or `eprintln!` anywhere in your component code, it will compile cleanly, deploy successfully, and then panic the moment it runs.

**The error:**

```
wasm backtrace:
  std::io::stdio::_print::...
  ...
Caused by: wasm trap: wasm `unreachable` instruction executed
```

That `_print` in the backtrace is the tell. It can be deeply nested — in a library you're using, in a debug impl, anywhere.

**The fix:**

Grep your entire component for `println!` and `eprintln!` before you deploy. Use `host::log` instead:

```rust
use crate::bindings::host;
use wavs_types::LogLevel;  // or your bindings path

host::log(LogLevel::Info, &format!("job_id={}, url={}", job_id, url));
```

If you're using a library that prints, you may need to check its source or add `--cfg` flags to suppress its output.

---

## 3. `usize` is 4 bytes in WASM32

Rust's `usize` is pointer-sized. In WASM32, that means 4 bytes, not 8. This causes a subtle bug when you're manually ABI-decoding strings from an `eth_call` result.

**The pattern that breaks:**

```rust
// ABI-encoded string: 32 bytes offset + 32 bytes length + N bytes data
let len = usize::from_be_bytes(result_bytes[56..64].try_into().unwrap());
//                             ^^^^^^^^^^^^^^^^^^^
// TryFromSliceError: [u8; 8] cannot convert to [u8; 4]
```

`from_be_bytes` for `usize` on WASM32 expects a 4-byte array, but you're giving it 8 bytes from the ABI encoding. It panics.

**The fix:**

Always use `u64::from_be_bytes` for ABI lengths, then cast:

```rust
let len = u64::from_be_bytes(result_bytes[56..64].try_into().unwrap()) as usize;
```

`u64::from_be_bytes` takes exactly 8 bytes on every platform. Then cast to `usize` for indexing. This works correctly on both WASM32 and native.

---

## 4. alloy can't decode mixed static/dynamic tuples in WASM

Alloy's `abi_decode_returns` panics in WASM when decoding tuples that contain both dynamic types (like `string`) and static types (like `address`, `uint256`) together.

**The error:**

```
getJob decode: type check failed for "offset (usize)" with data: ...
```

This happens because alloy uses `usize` internally for offset calculations, and the WASM32/64 mismatch corrupts the decode logic.

**Our workaround for ERC-8183:**

Instead of calling `getJob(uint256)` which returns a full tuple:

```solidity
function getJob(uint256 jobId) external view returns (
    address client,
    address provider,
    address evaluator,
    address hook,
    string memory description,  // ← dynamic, causes the bug
    uint256 budget,
    uint64 deadline,
    JobStatus status
);
```

We added a dedicated string-only getter:

```solidity
function getJobDescription(uint256 jobId) external view returns (string memory);
```

And decoded the result manually:

```rust
// ABI-encoded string: [0..32] = offset (32), [32..64] = length, [64..64+len] = data
let len = u64::from_be_bytes(result_bytes[56..64].try_into().unwrap()) as usize;
let url = String::from_utf8(result_bytes[64..64 + len].to_vec())?;
```

If you're reading from contracts you can't modify, use type-specific view functions for any return value that contains a `string` or `bytes` alongside static types.

---

## 5. Bash `$()` strips trailing newlines — wrong keccak hashes

This one is a shell scripting gotcha, not a Rust one, but it wasted an embarrassing amount of time.

**The bug:**

```bash
# This is WRONG
BODY=$(curl -sf "https://example.com/api")
DELIVERABLE=$(echo -n "$BODY" | cast keccak)
```

Bash command substitution (`$()`) strips trailing newlines from the captured output. Your WAVS component fetches the URL and hashes the raw bytes, including any trailing `\n`. The shell script captures the response, strips the newline, and produces a different hash. The hashes never match. Every job gets rejected.

**The fix:**

Pipe directly, no intermediate variable:

```bash
DELIVERABLE=$(curl -sf "https://example.com/api" | cast keccak)
```

`cast keccak` reads from stdin and hashes exactly what it receives. No stripping. The hash now matches what the WASM component computes.

---

## 6. Stale service registrations keep old broken components alive

Every time you re-deploy a WAVS service with a new component digest, the old service registration doesn't go away. If you've registered two services watching the same event hash, both fire on every event. The old broken one will keep producing errors even after you've fixed the new one.

**The symptom:**

You're seeing error messages in logs that reference a string or error message you thought you already removed. The address of the broken function in the backtrace doesn't match your new binary. That's because the old binary is still running.

**The fix:**

Restart WAVS to clear all in-memory service state. When re-registering, look up the service by ServiceManager address rather than taking `service_ids[-1]`:

```bash
SERVICE_ID=$(curl -sf "$WAVS_URL/services" | python3 -c "
import json,sys; d=json.load(sys.stdin); sm='$SM_ADDR'.lower()
for i,s in enumerate(d['services']):
  if s.get('manager',{}).get('evm',{}).get('address','').lower()==sm:
    print(d['service_ids'][i]); break")
```

This ensures you're using the service tied to your specific ServiceManager, not whatever was registered most recently.

---

## Putting It Together: The ERC-8183 Flow

With all six gotchas fixed, the ERC-8183 Agentic Commerce evaluator works cleanly:

1. Client creates a job on-chain with a deliverable hash (keccak256 of expected response body) and a URL
2. Provider does the work and calls `submit(jobId, deliverableHash)` on-chain
3. `JobSubmitted` event fires → WAVS operator component picks it up
4. Component calls `getJobDescription(jobId)` via raw WASI HTTP POST to the Anvil JSON-RPC → gets the URL
5. Component fetches the URL via raw WASI HTTP GET → hashes the response body
6. If `keccak256(body) == deliverable`, returns `EvaluationResult { jobId, isComplete: true, attestation }`
7. Aggregator collects signatures, calls `handleSignedEnvelope` on `AgenticCommerceEvaluator`
8. Contract calls `acp.complete(jobId, attestation)` → escrow releases to provider
9. `ReputationHook` writes `+100` feedback to the ERC-8004 reputation registry

End-to-end, from `JobSubmitted` on-chain to provider getting paid: one block.

The full example is in `examples/agents/01-agentic-commerce/`. The demo script is `scripts/demo-agentic-commerce.sh`.

---

## Quick Reference

| Symptom | Cause | Fix |
|---|---|---|
| WAVS drops triggers silently | `wstd`/`wavs-wasi-utils` in operator component | Raw WASI HTTP + `fut.subscribe().block()` |
| `std::io::stdio::_print` in backtrace | `println!` in component | Use `host::log` |
| `length slice error` | `usize::from_be_bytes` with 8 bytes on WASM32 | Use `u64::from_be_bytes(...) as usize` |
| `type check failed for "offset (usize)"` | alloy decoding mixed tuple with `string` | Single-value getter + manual decode |
| Deliverable hash never matches | bash `$()` strips trailing `\n` | `curl url \| cast keccak` directly |
| Old errors in logs after fix | Stale service registration | Restart WAVS, look up service by SM address |

---

The code is all in the [wavs-examples repository](https://github.com/JakeHartnell/wavs-examples) on the `examples` branch.
