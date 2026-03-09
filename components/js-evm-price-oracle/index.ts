/**
 * JS/TypeScript WAVS component: EVM Price Oracle
 *
 * Fetches a cryptocurrency price from CoinMarketCap by CMC ID
 * and returns it as JSON for on-chain submission.
 *
 * Compiled to WASM using @bytecodealliance/componentize-js 0.18.x.
 *
 * Key constraints:
 * 1. NO ethers.js — WAVS stubs wasi:random as `unreachable`. Ethers calls
 *    crypto.getRandomValues on import → instant trap.
 * 2. Exported `run` must match the generated sync type signature.
 *    componentize-js handles the async/JSPI bridging internally.
 * 3. For the Err variant, throw a plain string (not `new Error(...)`).
 *    The CABI calls utf8Encode(e) directly, requiring a string primitive.
 */
import { TriggerAction, WasmResponse } from "./out/wavs_operator_2_7_0.js";
import { decodeTriggerEvent, encodeOutput, Destination } from "./trigger.js";

/**
 * Main entry point exported to the WAVS runtime.
 * WIT: run(trigger-action: trigger-action) -> result<list<wasm-response>, string>
 *
 * Note: declared async because fetch() is used internally; componentize-js
 * JSPI compiles this to a synchronous WIT export via fiber suspension.
 * The return type matches the jco-generated sync signature at the WIT level.
 */
export async function run(triggerAction: TriggerAction): Promise<WasmResponse[]> {
  try {
    const [triggerInfo, destination] = decodeTriggerEvent(triggerAction.data);

    const num = new TextDecoder().decode(triggerInfo.data).trim();
    const id = parseInt(num, 10);
    if (isNaN(id)) {
      throw `Invalid CMC ID: "${num}"`;
    }

    const priceFeed = await fetchCryptoPrice(id);
    const json = JSON.stringify(priceFeed);
    const encoded = new TextEncoder().encode(json);

    switch (destination) {
      case Destination.Cli:
        return [{ payload: encoded, ordering: undefined, eventIdSalt: undefined }];
      case Destination.Ethereum:
        return [{ payload: encodeOutput(triggerInfo.triggerId, encoded), ordering: undefined, eventIdSalt: undefined }];
      default:
        throw `Unknown destination: ${destination}`;
    }
  } catch (e) {
    // Must throw a plain string for the WIT result<T, string> Err variant.
    // Do NOT throw Error objects — the CABI utf8Encode call expects string primitives.
    if (typeof e === "string") throw e;
    throw String(e);
  }
}

// ─── CoinMarketCap API ────────────────────────────────────────────────────────

interface CmcRoot {
  status: { timestamp: string };
  data: { symbol: string; statistics: { price: number } };
}

interface PriceFeedData {
  symbol: string;
  price: number;
  timestamp: string;
}

async function fetchCryptoPrice(id: number): Promise<PriceFeedData> {
  const url = `https://api.coinmarketcap.com/data-api/v3/cryptocurrency/detail?id=${id}&range=1h`;

  const response = await fetch(url, {
    method: "GET",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "User-Agent":
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36",
    },
  });

  if (!response.ok) {
    throw `HTTP ${response.status} from CoinMarketCap`;
  }

  const root: CmcRoot = await response.json();
  const price = Math.round(root.data.statistics.price * 100) / 100;
  const timestamp = root.status.timestamp.split(".")[0];

  return { symbol: root.data.symbol, price, timestamp };
}
