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

# componentize-py raises componentize_py_types.Err (a BaseException subclass)
# when WASI functions signal an error. We use this to catch end-of-stream.
_CpyErr = type(Err(None))

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
    print(f"[http] sending GET {url}")
    future = outgoing_handler.handle(req, None)

    # Block until the response is ready
    # Always poll via the subscribe pollable — never spin without yielding
    polls = 0
    while True:
        result = future.get()
        if result is None:
            pollable = future.subscribe()
            wasi_poll.poll([pollable])
            polls += 1
            continue

        # result: Ok(Ok(IncomingResponse)) | Ok(Err(ErrorCode)) | Err(None)
        if isinstance(result, Err):
            raise RuntimeError(f"HTTP send failed: {result.value}")
        if isinstance(result.value, Err):
            raise RuntimeError(f"HTTP error: {result.value.value}")

        response = result.value.value
        break

    status = response.status()
    print(f"[http] response status={status} polls={polls}")
    if status < 200 or status >= 300:
        raise RuntimeError(f"HTTP {status} from {url}")

    # Read the response body.
    # WASI InputStream.read() returns empty bytes when no data is immediately
    # available (non-blocking). We MUST subscribe/poll on the stream's pollable
    # before each read to avoid spinning on empty reads until the engine kills us.
    body = response.consume()
    stream = body.stream()

    data = bytearray()
    while True:
        # Wait until data is available (or stream is closed)
        stream_poll = stream.subscribe()
        wasi_poll.poll([stream_poll])
        try:
            chunk = stream.read(READ_SIZE)
            if chunk:
                data.extend(chunk)
            # empty chunk after poll = transient, loop again
        except _CpyErr as e:
            # componentize-py raises Err(StreamError_Closed()) at EOF
            if isinstance(e.value, StreamError_Closed):
                break
            raise RuntimeError(f"Stream read error: {e.value}")

    # Drop the InputStream explicitly.
    # We do NOT call IncomingBody.finish() — it requires all child resources
    # (InputStream) to be fully released first, but CPython's refcount doesn't
    # synchronously drop WASM resources, causing "resource has children" errors.
    del stream
    print(f"[http] body read complete: {len(data)} bytes")
    return bytes(data)
