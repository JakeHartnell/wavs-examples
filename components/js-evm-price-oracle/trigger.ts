/**
 * Trigger decoding helpers for WAVS operator@2.7.0
 *
 * Handles both on-chain EVM contract events and CLI (raw) inputs.
 *
 * NOTE: No ethers.js — WAVS stubs wasi:random as `unreachable` for
 * determinism, and ethers.js calls crypto.getRandomValues on import.
 * All ABI encode/decode is done manually.
 */
import { TriggerData } from "./out/interfaces/wavs-types-events.js";

export enum Destination {
  Cli = "Cli",
  Ethereum = "Ethereum",
}

export interface TriggerInfo {
  triggerId: number;
  creator: string;
  data: Uint8Array;
}

// ─── ABI helpers ────────────────────────────────────────────────────────────

/** Read a big-endian uint256 from 32 bytes at offset, return as BigInt */
function readUint256(buf: Uint8Array, offset: number): bigint {
  let v = 0n;
  for (let i = 0; i < 32; i++) {
    v = (v << 8n) | BigInt(buf[offset + i]);
  }
  return v;
}

/** Read a uint64 from the low 8 bytes of a 32-byte word */
function readUint64(buf: Uint8Array, offset: number): number {
  // The value is right-aligned in a 32-byte slot
  let v = 0;
  for (let i = 24; i < 32; i++) {
    v = (v * 256 + buf[offset + i]);
  }
  return v;
}

/** Read a 20-byte Ethereum address from the low 20 bytes of a 32-byte word */
function readAddress(buf: Uint8Array, offset: number): string {
  const bytes = buf.slice(offset + 12, offset + 32);
  return "0x" + Array.from(bytes).map(b => b.toString(16).padStart(2, "0")).join("");
}

/** Read `bytes` from an ABI-encoded dynamic type at the given base offset */
function readBytes(buf: Uint8Array, baseOffset: number, dynOffset: bigint): Uint8Array {
  const start = Number(dynOffset);
  const len = readUint64(buf, baseOffset + start);
  return buf.slice(baseOffset + start + 32, baseOffset + start + 32 + len);
}

/**
 * Decode an ABI-encoded `TriggerInfo { uint64 triggerId; address creator; bytes data; }`.
 * The outer NewTrigger event has `abi.encode(triggerInfo)` as the bytes payload,
 * which is itself wrapped in `abi.encode(bytes)` in the event data.
 */
function decodeTriggerInfo(eventData: Uint8Array): TriggerInfo {
  // The event data is: abi.encode(bytes _triggerInfo)
  // Layout: offset(32) | length(32) | triggerInfoBytes
  // The inner triggerInfoBytes starts at byte 64
  const innerOffset = readUint64(eventData, 0);   // should be 32
  const innerLen = readUint64(eventData, 32);
  const inner = eventData.slice(64, 64 + innerLen);

  // abi.encode(TriggerInfo) adds a 32-byte offset prefix before the tuple
  // because TriggerInfo contains a dynamic field (bytes data).
  // So inner = 0x20(32 bytes) + tuple data
  const tuple = inner.slice(32);

  // Tuple layout (after the 0x20 offset prefix):
  // [0:32]   triggerId  (uint64, right-aligned)
  // [32:64]  creator    (address, right-aligned)
  // [64:96]  offset to data field (= 0x60 = 96)
  // [96:128] length of data
  // [128..]  data bytes (padded to 32-byte boundary)
  const triggerId = readUint64(tuple, 0);
  const creator = readAddress(tuple, 32);
  const dataOffset = readUint64(tuple, 64); // should be 96
  const dataLen = readUint64(tuple, 96);
  const data = tuple.slice(128, 128 + dataLen);

  return { triggerId, creator, data };
}

/**
 * ABI-encode the output for on-chain submission.
 * Matches ITypes.sol: struct DataWithId { uint64 triggerId; bytes data; }
 *
 * Equivalent to alloy's `.abi_encode()` on DataWithId — same as Solidity's
 * `abi.encode(dataWithId)` which `abi.decode(payload, (DataWithId))` expects.
 *
 * DataWithId is a dynamic type (contains `bytes`), so the encoding includes
 * a 32-byte outer offset pointer before the struct fields:
 *
 *   [0:32]   = 0x20 (outer offset → struct data starts at byte 32)
 *   [32:64]  = triggerId (uint64, right-aligned)
 *   [64:96]  = 0x40 (offset to bytes, relative to byte 32 → bytes at byte 96)
 *   [96:128] = dataLen
 *   [128:…]  = data (zero-padded to 32-byte boundary)
 */
export function encodeOutput(triggerId: number, outputData: Uint8Array): Uint8Array {
  const dataLen = outputData.length;
  const padLen = (32 - (dataLen % 32)) % 32;
  const total = 32 + 96 + dataLen + padLen;  // +32 for outer offset word

  const buf = new Uint8Array(total);
  const view = new DataView(buf.buffer);

  // Word 0: outer offset — struct data starts at byte 32
  view.setBigUint64(24, 32n, false);

  // Word 1 (byte 32): triggerId — uint64 right-aligned
  view.setBigUint64(56, BigInt(triggerId), false);

  // Word 2 (byte 64): offset to bytes data = 64 (relative to byte 32, so bytes at byte 96)
  view.setBigUint64(88, 64n, false);

  // Word 3 (byte 96): length of bytes data
  view.setBigUint64(120, BigInt(dataLen), false);

  // Byte 128+: bytes data
  buf.set(outputData, 128);

  return buf;
}

/**
 * Decode a WAVS trigger event (on-chain or CLI).
 */
export function decodeTriggerEvent(
  triggerData: TriggerData
): [TriggerInfo, Destination] {
  if (triggerData.tag === "raw") {
    return [
      { triggerId: 0, creator: "", data: triggerData.val },
      Destination.Cli,
    ];
  }

  if (triggerData.tag === "evm-contract-event") {
    const { log } = triggerData.val;

    try {
      // In wavs:operator@2.7.0, log.data is EvmEventLogData { topics: Uint8Array[], data: Uint8Array }
      const eventData = log.data.data;
      const triggerInfo = decodeTriggerInfo(eventData);

      return [triggerInfo, Destination.Ethereum];
    } catch (error) {
      throw new Error("Error processing evm-contract-event: " + error);
    }
  }

  throw new Error(
    "Unsupported trigger data type: " + (triggerData as any).tag
  );
}
