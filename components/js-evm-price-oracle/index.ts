/**
 * JS/TypeScript WAVS component: EVM Price Oracle
 *
 * Fetches a cryptocurrency price from CoinMarketCap by CMC ID
 * and returns it as JSON for on-chain submission.
 *
 * Demonstrates writing WAVS components in JavaScript/TypeScript.
 * Compiled to WASM using @bytecodealliance/componentize-js.
 */
import { TriggerAction, WasmResponse } from "./out/wavs_operator_2_7_0.js";
import { decodeTriggerEvent, encodeOutput, Destination } from "./trigger.js";

/**
 * Main entry point exported to the WAVS runtime.
 * Must match the WIT signature:
 *   run: func(trigger-action: trigger-action) -> result<list<wasm-response>, string>
 */
async function run(triggerAction: TriggerAction): Promise<WasmResponse[]> {
  const [triggerInfo, destination] = decodeTriggerEvent(triggerAction.data);

  const result = await compute(triggerInfo.data);

  switch (destination) {
    case Destination.Cli:
      return [
        {
          payload: result,
          ordering: undefined,
          eventIdSalt: undefined,
        },
      ];
    case Destination.Ethereum:
      return [
        {
          payload: encodeOutput(triggerInfo.triggerId, result),
          ordering: undefined,
          eventIdSalt: undefined,
        },
      ];
    default:
      throw new Error(
        `Unknown destination: ${destination} for trigger ID: ${triggerInfo.triggerId}`
      );
  }
}

/**
 * Fetch and serialize a cryptocurrency price by CoinMarketCap ID.
 */
async function compute(input: Uint8Array): Promise<Uint8Array> {
  const num = new TextDecoder().decode(input).trim();
  const id = parseInt(num, 10);
  if (isNaN(id)) {
    throw new Error(`Invalid CMC ID: "${num}"`);
  }

  const priceFeed = await fetchCryptoPrice(id);
  const json = JSON.stringify(priceFeed);
  return new TextEncoder().encode(json);
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

  const currentTime = Math.floor(Date.now() / 1000);
  const response = await fetch(url, {
    method: "GET",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "User-Agent":
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36",
      Cookie: `myrandom_cookie=${currentTime}`,
    },
  });

  if (!response.ok) {
    throw new Error(`HTTP ${response.status} from CoinMarketCap`);
  }

  const root: CmcRoot = await response.json();
  const price = Math.round(root.data.statistics.price * 100) / 100;
  const timestamp = root.status.timestamp.split(".")[0];

  return { symbol: root.data.symbol, price, timestamp };
}

export { run };
