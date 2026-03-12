"""
Synchronous HTTP GET helper using WASI outgoing-handler.

componentize-py's bundled poll_loop.py targets the wasi:http/proxy world
where the HTTP types module is imported as `types`. In the WAVS world they
are imported as `wasi_http_types`. Rather than patching poll_loop, we
implement a minimal blocking HTTP client directly using the correct import
names.

No asyncio or external dependencies required — WASM is single-threaded so
a simple polling loop is all we need.
"""

import json
from typing import Any
from urllib.parse import urlparse

from componentize_py_types import Ok, Err

from wit_world.imports import outgoing_handler, poll as wasi_poll
from wit_world.imports.wasi_http_types import (
    OutgoingRequest,
    Fields,
    IncomingBody,
    Scheme_Http,
    Scheme_Https,
    Scheme_Other,
)
from wit_world.imports.streams import StreamError_Closed

READ_SIZE = 16 * 1024


def http_get_json(url: str, headers: dict | None = None) -> Any:
    """Perform a blocking HTTP GET and return the parsed JSON body.

    Args:
        url:     Full URL to fetch (http:// or https://)
        headers: Optional additional request headers (str → str)

    Returns:
        Parsed JSON value

    Raises:
        RuntimeError on HTTP error or JSON parse failure
    """
    body_bytes = _http_get(url, headers or {})
    return json.loads(body_bytes)


def _http_get(url: str, extra_headers: dict) -> bytes:
    parsed = urlparse(url)

    # Build header list — Fields.from_list takes List[Tuple[str, bytes]]
    header_list = [
        ("Accept", b"application/json"),
        ("User-Agent", b"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"),
    ]
    for k, v in extra_headers.items():
        header_list.append((k, v.encode() if isinstance(v, str) else v))

    fields = Fields.from_list(header_list)
    req = OutgoingRequest(fields)

    match parsed.scheme:
        case "https":
            req.set_scheme(Scheme_Https())
        case "http":
            req.set_scheme(Scheme_Http())
        case other:
            req.set_scheme(Scheme_Other(other))

    req.set_authority(parsed.netloc)

    path_query = parsed.path
    if parsed.query:
        path_query += "?" + parsed.query
    req.set_path_with_query(path_query)

    # Send request — returns a FutureIncomingResponse
    future = outgoing_handler.handle(req, None)

    # Block until the response is ready
    while True:
        result = future.get()
        if result is None:
            # Not ready yet — poll on the subscribe pollable
            pollable = future.subscribe()
            wasi_poll.poll([pollable])
            continue

        # result: Ok(Ok(IncomingResponse)) | Ok(Err(ErrorCode)) | Err(None)
        if isinstance(result, Err):
            raise RuntimeError(f"HTTP send failed: {result.value}")
        if isinstance(result.value, Err):
            raise RuntimeError(f"HTTP error: {result.value.value}")

        response = result.value.value
        break

    status = response.status()
    if status < 200 or status >= 300:
        raise RuntimeError(f"HTTP {status} from {url}")

    # Read the response body
    body = response.consume()
    stream = body.stream()

    data = bytearray()
    while True:
        try:
            chunk = stream.read(READ_SIZE)
            data.extend(chunk)
        except StreamError_Closed:
            break
        except Exception as e:
            # WASI streams raise on end-of-stream — check for closed
            err_str = str(e)
            if "Closed" in err_str or "closed" in err_str:
                break
            raise RuntimeError(f"Stream read error: {e}")

    IncomingBody.finish(body)
    return bytes(data)
