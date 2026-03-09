/**
 * Trigger decoding helpers for WAVS operator@2.7.0
 *
 * Handles both on-chain EVM contract events and CLI (raw) inputs.
 * Uses ethers.js v6 for ABI encoding/decoding.
 */
import { TriggerData } from "./out/interfaces/wavs-types-events.js";
import { AbiCoder, Interface, getBytes, hexlify } from "ethers";

export enum Destination {
  Cli = "Cli",
  Ethereum = "Ethereum",
}

// Solidity types from ITypes.sol
const DATA_WITH_ID_TYPE = "tuple(uint64 triggerId, bytes data)";
const TRIGGER_INFO_TYPE = "tuple(uint64 triggerId, address creator, bytes data)";
const EVENT_NAME = "NewTrigger";
const eventInterface = new Interface([`event ${EVENT_NAME}(bytes _triggerInfo)`]);

export interface TriggerInfo {
  triggerId: number;
  creator: string;
  data: Uint8Array;
}

/**
 * ABI-encode the trigger output for on-chain submission.
 * Matches the DataWithId struct in ITypes.sol.
 */
export function encodeOutput(triggerId: number, outputData: Uint8Array): Uint8Array {
  const encoded = new AbiCoder().encode(
    [DATA_WITH_ID_TYPE],
    [{ triggerId, data: outputData }]
  );
  return getBytes(encoded);
}

/**
 * Decode a WAVS trigger event (on-chain or CLI).
 *
 * In wavs:operator@2.7.0, TriggerData is a discriminated union:
 *   { tag: 'raw', val: Uint8Array }               — CLI / wasi-exec testing
 *   { tag: 'evm-contract-event', val: { chain, log } } — on-chain EVM event
 *
 * NOTE: In 2.7.0 the EvmEventLog structure is:
 *   log.data.topics: Array<Uint8Array>  (was log.topics in @0.4.0)
 *   log.data.data:   Uint8Array         (was log.data in @0.4.0)
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
      // In @2.7.0, log.data is EvmEventLogData { topics: Uint8Array[], data: Uint8Array }
      const topics = log.data.topics.map((t) => hexlify(t));
      const decodedEvent = eventInterface.decodeEventLog(
        EVENT_NAME,
        log.data.data,
        topics
      );

      const [triggerInfo] = new AbiCoder().decode(
        [TRIGGER_INFO_TYPE],
        decodedEvent._triggerInfo
      );

      return [
        {
          triggerId: Number(triggerInfo.triggerId),
          creator: triggerInfo.creator,
          data: getBytes(triggerInfo.data),
        },
        Destination.Ethereum,
      ];
    } catch (error) {
      throw new Error("Error processing evm-contract-event: " + error);
    }
  }

  throw new Error(
    "Unsupported trigger data type: " + (triggerData as any).tag
  );
}
