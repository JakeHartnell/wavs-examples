"""
ABI decode/encode helpers for the WAVS EVM price oracle.

Manually decodes the NewTrigger event and encodes the DataWithId output —
no external libraries required, pure Python byte manipulation.

Logic ported directly from the Go implementation (trigger.go).
"""

import struct
from typing import Tuple

from wit_world.imports import events


# ─── Destination ─────────────────────────────────────────────────────────────

DEST_CLI = "cli"
DEST_EVM = "evm"


def decode_trigger(data: events.TriggerData) -> Tuple[int, bytes, str]:
    """Decode a WAVS TriggerData into (trigger_id, input_bytes, destination).

    Raw trigger  → CLI path (input_bytes = raw bytes, trigger_id = 0)
    EVM trigger  → on-chain path (input_bytes = CMC ID as UTF-8)
    """
    if isinstance(data, events.TriggerData_Raw):
        raw = data.value.rstrip(b"\x00")
        return 0, raw, DEST_CLI

    if isinstance(data, events.TriggerData_EvmContractEvent):
        log = data.value.log
        # log.data.data = raw ABI bytes from NewTrigger(bytes _triggerInfo)
        trigger_id, input_bytes = _decode_trigger_info(log.data.data)
        return trigger_id, input_bytes, DEST_EVM

    raise ValueError(f"Unsupported trigger type: {type(data).__name__}")


def encode_output(trigger_id: int, data: bytes) -> bytes:
    """ABI-encode DataWithId { uint64 triggerId; bytes data } for on-chain submission.

    Matches Rust alloy's .abi_encode() for a dynamic struct — includes the outer
    32-byte tuple offset prefix that abi.decode(payload, (DataWithId)) requires.

    Layout:
      [0:32]    outer offset = 0x20 (= 32, pointing to struct start)
      [32:64]   triggerId  (uint64, right-aligned in 32 bytes)
      [64:96]   offset to data bytes from struct start (= 0x40 = 64)
      [96:128]  length of data bytes
      [128..]   data bytes (zero-padded to 32-byte boundary)

    Note: abi.decode(payload, (DataWithId)) expects this format —
    it decodes a 1-tuple (DataWithId,) which adds an outer offset word.
    Without this prefix, the decode silently produces wrong values and reverts.
    """
    data_len = len(data)
    pad_len = (32 - data_len % 32) % 32 if data_len % 32 != 0 else 0
    buf = bytearray(128 + data_len + pad_len)

    # outer offset = 32 (0x20) — required by abi.decode for dynamic structs
    struct.pack_into(">Q", buf, 24, 32)

    # triggerId — uint64 right-aligned in second 32-byte word
    struct.pack_into(">Q", buf, 56, trigger_id)

    # offset to data from struct start = 64 (0x40)
    struct.pack_into(">Q", buf, 88, 64)

    # data length
    struct.pack_into(">Q", buf, 120, data_len)

    # data bytes
    buf[128:128 + data_len] = data

    return bytes(buf)


# ─── Internal ─────────────────────────────────────────────────────────────────

def _decode_trigger_info(raw: bytes) -> Tuple[int, bytes]:
    """Decode a NewTrigger event payload into (trigger_id, data_bytes).

    The Solidity event is:
        event NewTrigger(bytes _triggerInfo)
    where _triggerInfo = abi.encode(TriggerInfo{triggerId, creator, data}).

    Outer event ABI layout (bytes as a dynamic type):
      [0:32]   offset to _triggerInfo (= 0x20)
      [32:64]  length of _triggerInfo bytes
      [64:N]   _triggerInfo ABI bytes

    TriggerInfo ABI layout (after skipping 32-byte ABI-prefix for struct):
      [0:32]    triggerId  (uint64, right-aligned)
      [32:64]   creator    (address, right-aligned)
      [64:96]   offset to data bytes (= 0x60)
      [96:128]  length of data bytes
      [128..]   data bytes (CMC ID as UTF-8, padded to 32-byte boundary)
    """
    if len(raw) < 96:
        raise ValueError(f"Event data too short: {len(raw)} bytes")

    # Extract inner length + bytes from the outer bytes wrapper
    inner_len = struct.unpack_from(">Q", raw, 56)[0]   # bytes 56–63 of 32-byte length word
    inner_start = 64
    if len(raw) < inner_start + inner_len:
        raise ValueError(f"Inner data truncated: need {inner_start + inner_len}, have {len(raw)}")

    inner = raw[inner_start: inner_start + inner_len]

    # Skip the 32-byte ABI tuple offset prefix (= 0x20 = 32)
    if len(inner) < 32:
        raise ValueError(f"Inner too short for ABI offset header: {len(inner)} bytes")
    inner = inner[32:]

    # Parse TriggerInfo fields
    if len(inner) < 128:
        raise ValueError(f"TriggerInfo too short: {len(inner)} bytes")

    trigger_id = struct.unpack_from(">Q", inner, 24)[0]   # low 8B of 32-byte word
    # creator = inner[44:64] — not needed for price oracle

    data_len = struct.unpack_from(">Q", inner, 120)[0]    # low 8B of 32-byte length word
    data_start = 128
    if len(inner) < data_start + data_len:
        raise ValueError(f"Trigger data truncated: need {data_start + data_len}, have {len(inner)}")

    data = inner[data_start: data_start + data_len]
    return trigger_id, data
