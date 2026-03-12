"""
WAVS component: EVM Price Oracle (Python)

Triggered on-chain with a CoinMarketCap ID → fetches the price →
returns ABI-encoded DataWithId for on-chain submission.

Uses componentize-py to compile Python → WASM component targeting
the wavs:operator/wavs-world WIT world (WASI Preview 2).

Build:
    componentize-py -d ./wit-clean -w wavs:operator/wavs-world \
        componentize component -o ../../compiled/python_evm_price_oracle.wasm
"""

import json
import math
from typing import List

import wit_world
from wit_world.imports import input, output

from trigger import decode_trigger, encode_output, DEST_EVM, DEST_CLI
from http_client import http_get_json


# ─── CoinMarketCap ────────────────────────────────────────────────────────────

CMC_URL = (
    "https://api.coinmarketcap.com/data-api/v3/cryptocurrency/detail"
    "?id={cmc_id}&range=1h"
)


def fetch_price(cmc_id: int) -> dict:
    """Fetch current price for a CoinMarketCap cryptocurrency ID.

    Returns:
        { "symbol": str, "price": float, "timestamp": str }
    """
    url = CMC_URL.format(cmc_id=cmc_id)
    body = http_get_json(url)

    symbol = body["data"]["symbol"]
    price = math.floor(body["data"]["statistics"]["price"] * 100) / 100
    # Timestamp arrives as "2025-04-30T19:59:44.161Z" — strip sub-seconds
    timestamp = body["status"]["timestamp"].split(".")[0]

    return {"symbol": symbol, "price": price, "timestamp": timestamp}


# ─── WAVS component entrypoint ────────────────────────────────────────────────

class WitWorld(wit_world.WitWorld):
    """WAVS component implementing wavs:operator/wavs-world."""

    def run(self, trigger_action: input.TriggerAction) -> List[output.WasmResponse]:
        """Main entrypoint called by the WAVS runtime.

        Raises:
            str on any error (WAVS maps this to the Err variant of result<_, string>)
        """
        try:
            trigger_id, cmc_id_bytes, dest = decode_trigger(trigger_action.data)

            # Parse CMC ID from UTF-8 bytes
            cmc_id_str = cmc_id_bytes.decode("utf-8").strip()
            cmc_id = int(cmc_id_str)

            print(f"Fetching price for CMC ID: {cmc_id}")
            price_data = fetch_price(cmc_id)
            print(f"Price data: {price_data}")

            price_json = json.dumps(price_data).encode("utf-8")

            if dest == DEST_EVM:
                payload = encode_output(trigger_id, price_json)
                print(f"ABI-encoded output ({len(payload)} bytes)")
            else:
                # CLI / raw trigger — return JSON directly
                payload = price_json

            return [
                output.WasmResponse(
                    payload=payload,
                    ordering=None,
                    event_id_salt=None,
                )
            ]

        except Exception as e:
            raise str(e)
