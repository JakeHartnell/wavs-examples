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


# ─── CoinGecko (lightweight, no API key) ─────────────────────────────────────
#
# CoinMarketCap's detail endpoint returns ~50 KB which is slow to stream
# through WASI HTTP. CoinGecko's simple/price returns ~25 bytes — much faster.
#
# CMC ID → CoinGecko slug lookup (extend as needed)
_CMC_TO_COINGECKO = {
    1:    "bitcoin",
    2:    "litecoin",
    52:   "ripple",
    74:   "dogecoin",
    825:  "tether",
    1027: "ethereum",
    1839: "binancecoin",
    5426: "solana",
    3408: "usd-coin",
}

COINGECKO_URL = (
    "https://api.coingecko.com/api/v3/simple/price"
    "?ids={coin_id}&vs_currencies=usd"
)


def fetch_price(cmc_id: int) -> dict:
    """Fetch current USD price using CoinGecko's lightweight simple/price API.

    Returns:
        { "symbol": str, "price": float, "timestamp": str }
    """
    coin_id = _CMC_TO_COINGECKO.get(cmc_id, "bitcoin")
    # Use the CMC symbol name for display; derive from coin_id as fallback
    symbol = coin_id.upper().replace("-", "")

    url = COINGECKO_URL.format(coin_id=coin_id)
    print(f"[price] GET {url}")
    body = http_get_json(url)

    price = float(body[coin_id]["usd"])
    # CoinGecko doesn't return a timestamp; use a placeholder
    timestamp = "2026-01-01T00:00:00"

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
            raise Exception(str(e))
