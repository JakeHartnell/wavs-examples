# Writing WAVS Components in TypeScript

*You already know JavaScript. Now it runs on-chain.*

---

JavaScript is the world's most widely-deployed language. There are more npm packages than atoms in the observable universe (approximately). If WAVS is going to live up to its promise of being language-agnostic, TypeScript support isn't optional — it's the thing that opens WAVS to the largest developer community.

Good news: it works, and it's surprisingly straightforward.

## How It Works

TypeScript WAVS components use [componentize-js](https://github.com/bytecodealliance/componentize-js) from the Bytecode Alliance. The idea is elegant: embed [SpiderMonkey](https://spidermonkey.dev/) — Firefox's JavaScript engine — directly inside the WASM binary. Your TypeScript gets compiled to JavaScript, that JavaScript runs inside SpiderMonkey, and SpiderMonkey is the WASM component.

The trade-off is size: SpiderMonkey adds ~13 MB baseline. The resulting `js_evm_price_oracle.wasm` weighs in at 15 MB compared to 1.3 MB for the Go equivalent and 507 KB for Rust. For a price oracle or API component, this is completely fine. For something that runs thousands of times per second, you'd reach for Rust.

The upside is that you get the *full* JavaScript runtime. `fetch()` works. `async/await` works. `JSON.parse()`, `Array.prototype.map()`, template literals — all of it, exactly as you'd expect in Node.js.

## The Build Pipeline

Getting from TypeScript to a WAVS component takes four steps:

```
WIT files ──wkg──▶ wavs_operator_2_7_0.wasm
                           │
                    jco types ▼
              TypeScript type definitions
                           │
               index.ts ──tsc──▶ index.js
               trigger.ts         trigger.js
                           │
                    esbuild ▼
                       out/out.js  (single bundled file)
                           │
              jco componentize ▼
               js_evm_price_oracle.wasm  ✅
```

**Step 1: Build the WIT package.** WAVS components implement `wavs:operator@2.7.0`. Since this version isn't on the public package registry yet, we build it from local WIT files:

```bash
wkg wit build --wit-dir ./wit -o wavs_operator_2_7_0.wasm
wasm-tools component wit wavs_operator_2_7_0.wasm -o wavs_operator_2_7_0.wit
```

**Step 2: Generate TypeScript types.** `jco types` introspects the WIT package and emits `.d.ts` files for every interface:

```bash
npx jco types wavs_operator_2_7_0.wasm --out-dir out/
```

This gives you proper TypeScript types for `TriggerAction`, `WasmResponse`, `TriggerData`, `EvmEventLog` — everything you'll work with.

**Step 3: Compile and bundle.** TypeScript → JavaScript via `tsc`, then bundled to a single file via `esbuild`:

```bash
npx tsc --outDir out/ index.ts trigger.ts --target ES2020 --module ES2020
npx esbuild ./out/index.js --bundle --outfile=out/out.js --format=esm
```

**Step 4: Componentize.** `jco componentize` wraps the bundled JS in SpiderMonkey and the WASI component adapter:

```bash
npx jco componentize out/out.js \
  --wit wavs_operator_2_7_0.wit \
  --world-name "wavs:operator/wavs-world" \
  --out ../../compiled/js_evm_price_oracle.wasm
```

All of this is wrapped in a single `make wasi-build`.

## The Component

The main entrypoint exports a `run` function matching the WIT signature:

```typescript
// The WIT world exports: run(trigger-action) -> result<list<wasm-response>, string>
// componentize-js maps thrown errors to the Err variant
async function run(triggerAction: TriggerAction): Promise<WasmResponse[]> {
  const [triggerInfo, destination] = decodeTriggerEvent(triggerAction.data);
  const result = await compute(triggerInfo.data);

  switch (destination) {
    case Destination.Cli:
      return [{ payload: result, ordering: undefined, eventIdSalt: undefined }];

    case Destination.Ethereum:
      return [{ payload: encodeOutput(triggerInfo.triggerId, result), ordering: undefined, eventIdSalt: undefined }];

    default:
      throw new Error(`Unknown destination for trigger ${triggerInfo.triggerId}`);
  }
}

export { run };
```

Notice that `run` is `async` and returns `Promise<WasmResponse[]>`. componentize-js handles the async runtime internally — you write naturally async JavaScript and it gets wired into the synchronous WASM export.

Throwing an error maps to the `Err` variant in the WIT result type. Returning an array maps to `Ok`. The mapping is clean.

## Decoding Triggers

In `wavs:operator@2.7.0`, `TriggerData` is a tagged union. The TypeScript types reflect this:

```typescript
// { tag: 'raw', val: Uint8Array }              — CLI testing
// { tag: 'evm-contract-event', val: {...} }     — on-chain event
type TriggerData = TriggerDataRaw | TriggerDataEvmContractEvent | ...;
```

Decoding an EVM event:

```typescript
function decodeTriggerEvent(triggerData: TriggerData): [TriggerInfo, Destination] {
  if (triggerData.tag === "raw") {
    return [{ triggerId: 0, creator: "", data: triggerData.val }, Destination.Cli];
  }

  if (triggerData.tag === "evm-contract-event") {
    const { log } = triggerData.val;

    // NOTE: In @2.7.0, log.data is EvmEventLogData { topics: Uint8Array[], data: Uint8Array }
    // (was log.topics / log.data directly in the old wavs:worker@0.4.0 API)
    const topics = log.data.topics.map((t) => hexlify(t));
    const decodedEvent = eventInterface.decodeEventLog("NewTrigger", log.data.data, topics);
    const [triggerInfo] = new AbiCoder().decode([TriggerInfo], decodedEvent._triggerInfo);

    return [
      { triggerId: Number(triggerInfo.triggerId), creator: triggerInfo.creator, data: getBytes(triggerInfo.data) },
      Destination.Ethereum,
    ];
  }

  throw new Error("Unsupported trigger type: " + (triggerData as any).tag);
}
```

ABI encoding uses `ethers.js v6` — the same library you'd use in any dApp frontend:

```typescript
function encodeOutput(triggerId: number, outputData: Uint8Array): Uint8Array {
  const encoded = new AbiCoder().encode(
    ["tuple(uint64 triggerId, bytes data)"],
    [{ triggerId, data: outputData }]
  );
  return getBytes(encoded);
}
```

This is a big ergonomics win over Go or Rust: the entire ethers.js ecosystem is available. ABI encoding, event parsing, address utilities — all of it.

## Fetching Data

The CoinMarketCap fetch is just... `fetch()`:

```typescript
async function fetchCryptoPrice(id: number): Promise<PriceFeedData> {
  const url = `https://api.coinmarketcap.com/data-api/v3/cryptocurrency/detail?id=${id}&range=1h`;

  const response = await fetch(url, {
    method: "GET",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "User-Agent": "Mozilla/5.0 ...",
      Cookie: `myrandom_cookie=${Math.floor(Date.now() / 1000)}`,
    },
  });

  if (!response.ok) throw new Error(`HTTP ${response.status}`);

  const root = await response.json();
  return {
    symbol: root.data.symbol,
    price: Math.round(root.data.statistics.price * 100) / 100,
    timestamp: root.status.timestamp.split(".")[0],
  };
}
```

No setup, no imports, no WASI boilerplate. The `fetch` global is provided by componentize-js's WASI adapter. It forwards the request through `wasi:http/outgoing-handler` under the hood, but from your code's perspective it's just fetch.

This is the core value proposition: **if you can write a Node.js script that hits an API and returns JSON, you can write a WAVS component.**

## Testing

```bash
# Bitcoin (CMC ID 1)
make wasi-exec COMPONENT_FILENAME=js_evm_price_oracle.wasm INPUT_DATA="1"
```

Output:
```
{"symbol":"BTC","price":83241.50,"timestamp":"2026-03-09T15:00:00"}
```

## Porting from wavs:worker@0.4.0

If you've seen the old JavaScript examples from the `wavs-foundry-template`, there are a few breaking changes in the `wavs:operator@2.7.0` API worth knowing:

| What changed | Old (`wavs:worker@0.4.0`) | New (`wavs:operator@2.7.0`) |
|---|---|---|
| World name | `layer-trigger-world` | `wavs-world` |
| `run` return type | `Promise<WasmResponse>` | `Promise<WasmResponse[]>` |
| EVM log structure | `log.topics`, `log.data` | `log.data.topics`, `log.data.data` |
| WasmResponse | `{payload, ordering}` | `{payload, ordering, eventIdSalt}` |
| WIT package | Published on registry | Build from local WIT |

The most impactful change is the return type: `run` now returns a *list* of responses, not an option. This enables components that produce multiple outputs from a single trigger — useful for things like multi-chain fan-out or batch processing.

## The WIT Package Situation

You might notice we're building the WIT package from local files instead of pulling `wavs:operator@2.7.0` from the `wa.dev` registry. That's because the registry is currently behind — it has `wavs:operator@2.1.0` but not `2.7.0`.

The fix: the `wkg` tool respects a `wkg.toml` that can override package resolution with local paths. We temporarily override all the `wavs:*` and `wasi:*` deps to point to the local `wit/deps/` directory, build the package, then restore the config:

```toml
# temporary wkg.toml override during build
[overrides]
"wavs:types" = { path = "./wit/deps/wavs-types-2.7.0" }
"wasi:cli"   = { path = "./wit/deps/wasi-cli-0.2.0" }
# ... etc
```

Once `wavs:operator@2.7.0` is published to the registry, `wkg get wavs:operator@2.7.0 --format wasm` will work directly.

## Summary

TypeScript WAVS components are for the developer who wants to:
- Use familiar tooling (npm, TypeScript, ethers.js)
- Move fast on logic-heavy components
- Leverage the npm ecosystem (parsers, crypto utils, formatters)
- Write async code without thinking about lifetimes or borrow checkers

The 15 MB binary size is the cost. For serverless-style oracle and automation use cases, it's a fine trade. For anything latency-sensitive or high-throughput, Rust is the right call.

But the point is: **you choose**. Same interface, same on-chain result, different language. That's what WAVS being WASM-native actually means.

The full source is in the [wavs-examples repository](https://github.com/JakeHartnell/wavs-examples) under `components/js-evm-price-oracle/`.
