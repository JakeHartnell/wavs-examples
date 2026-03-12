/**
 * WAVS component: EVM Price Oracle (JavaScript/TypeScript)
 *
 * Triggered on-chain with a CoinMarketCap ID → fetches the price →
 * returns ABI-encoded DataWithId for on-chain submission.
 *
 * Uses viem for ABI encoding/decoding — pure math, zero crypto dependencies,
 * works in WAVS without any polyfills.
 */
import { decodeAbiParameters, encodeAbiParameters } from "viem";
import type { TriggerAction, WasmResponse } from "./out/wavs_operator_2_7_0.js";

// ─── ABI schemas ──────────────────────────────────────────────────────────────

// SimpleTrigger.sol emits: event NewTrigger(bytes triggerData)
//   where triggerData = abi.encode(TriggerInfo{triggerId, creator, data})
const TRIGGER_INFO_ABI = [{ type: "tuple", components: [
  { name: "triggerId", type: "uint64"  },
  { name: "creator",   type: "address" },
  { name: "data",      type: "bytes"   },
] }] as const;

// ITypes.sol: struct DataWithId { uint64 triggerId; bytes data; }
const DATA_WITH_ID_ABI = [{ type: "tuple", components: [
  { name: "triggerId", type: "uint64" },
  { name: "data",      type: "bytes"  },
] }] as const;

// ─── Component entrypoint ─────────────────────────────────────────────────────

export async function run(triggerAction: TriggerAction): Promise<WasmResponse[]> {
  try {
    // Extract raw event bytes depending on trigger source
    if (triggerAction.data.tag !== "evm-contract-event" && triggerAction.data.tag !== "raw") {
      throw `Unsupported trigger type: ${triggerAction.data.tag}`;
    }
    const rawBytes =
      triggerAction.data.tag === "evm-contract-event"
        ? triggerAction.data.val.log.data.data
        : (triggerAction.data.val as Uint8Array);

    // componentize-js may pass bytes as plain objects {"0":0,"1":0,...} not Uint8Array
    const eventData = normalizeBytes(rawBytes);

    // Decode: event NewTrigger(bytes) wraps abi.encode(TriggerInfo)
    const [innerBytes] = decodeAbiParameters([{ type: "bytes" }], toHex(eventData));
    const [{ triggerId, creator: _creator, data }] = decodeAbiParameters(TRIGGER_INFO_ABI, innerBytes);

    // data = CoinMarketCap cryptocurrency ID as a UTF-8 string (e.g. "1" = BTC)
    const cmcId = parseInt(new TextDecoder().decode(fromHex(data)), 10);
    if (isNaN(cmcId)) throw `Invalid CMC ID in trigger data`;

    const price = await fetchCryptoPrice(cmcId);
    const priceBytes = new TextEncoder().encode(JSON.stringify(price));

    // Encode output as DataWithId for on-chain submission
    const payload = encodeAbiParameters(DATA_WITH_ID_ABI, [{
      triggerId,
      data: toHex(priceBytes),
    }]);

    return [{ payload: fromHex(payload), ordering: undefined, eventIdSalt: undefined }];
  } catch (e) {
    // Must throw a string — componentize-js requires a string primitive for Err(string)
    throw typeof e === "string" ? e : String(e);
  }
}

// ─── CoinMarketCap ────────────────────────────────────────────────────────────

async function fetchCryptoPrice(id: number) {
  const url = `https://api.coinmarketcap.com/data-api/v3/cryptocurrency/detail?id=${id}&range=1h`;
  const res = await fetch(url, { headers: {
    "Accept": "application/json",
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
  }});
  if (!res.ok) throw `HTTP ${res.status} from CoinMarketCap`;
  const body = await res.json() as any;
  return {
    symbol:    body.data.symbol as string,
    price:     Math.round(body.data.statistics.price * 100) / 100,
    timestamp: (body.status.timestamp as string).split(".")[0],
  };
}

// ─── Byte utils ───────────────────────────────────────────────────────────────

/**
 * Normalize bytes from WAVS/componentize-js.
 * The runtime may pass bytes as plain objects {"0":0,"1":0,...} rather than
 * a proper Uint8Array — this converts either form to a real Uint8Array.
 */
function normalizeBytes(data: any): Uint8Array {
  if (data instanceof Uint8Array) return data;
  // Plain object with numeric string keys
  const len = Object.keys(data).filter((k: string) => /^\d+$/.test(k)).length;
  const arr = new Uint8Array(len);
  for (let i = 0; i < len; i++) arr[i] = (data[i] as number) ?? 0;
  return arr;
}

function toHex(bytes: Uint8Array): `0x${string}` {
  return `0x${Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("")}`;
}

function fromHex(hex: `0x${string}`): Uint8Array {
  const s = hex.slice(2);
  const arr = new Uint8Array(s.length / 2);
  for (let i = 0; i < arr.length; i++) arr[i] = parseInt(s.slice(i * 2, i * 2 + 2), 16);
  return arr;
}
