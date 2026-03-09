package main

import (
	"encoding/binary"
	"fmt"

	inputTypes "github.com/Lay3rLabs/wavs-examples/components/golang-evm-price-oracle/gen/wavs/operator/input"
	chainTypes "github.com/Lay3rLabs/wavs-examples/components/golang-evm-price-oracle/gen/wavs/types/chain"
	"go.bytecodealliance.org/cm"
)

type destination int

const (
	destCLI      destination = iota
	destEthereum destination = iota
)

// decodeTriggerEvent decodes the WAVS trigger action into (triggerID, inputData, destination).
//
// In wavs:operator@2.7.0 TriggerData is a variant:
//   - Raw(list<u8>)                       — CLI / wasi-exec local testing
//   - EvmContractEvent(TriggerDataEvmContractEvent) — on-chain EVM event
//
// NOTE: In 2.7.0 the EVM log structure changed:
//
//	log.Data.Topics — [][]byte  (was log.Topics in @0.4.0)
//	log.Data.Data   — []byte    (was log.Data in @0.4.0)
func decodeTriggerEvent(data inputTypes.TriggerData) (triggerID uint64, input []byte, dest destination) {
	if raw := data.Raw(); raw != nil {
		fmt.Printf("Raw input: %s\n", string(raw.Slice()))
		return 0, raw.Slice(), destCLI
	}

	evmEvent := data.EvmContractEvent()
	if evmEvent == nil {
		panic("unsupported trigger data type: neither raw nor evm-contract-event")
	}

	log := evmEvent.Log
	triggerInfo := decodeTriggerInfo(log)

	fmt.Printf("Trigger ID: %d\n", triggerInfo.TriggerID)
	fmt.Printf("Creator:    %x\n", triggerInfo.Creator)
	fmt.Printf("Input data: %s\n", string(triggerInfo.Data))

	return triggerInfo.TriggerID, triggerInfo.Data, destEthereum
}

// triggerInfo holds the decoded on-chain trigger parameters.
type triggerInfo struct {
	TriggerID uint64
	Creator   []byte
	Data      []byte
}

// decodeTriggerInfo ABI-decodes the NewTrigger event log into a triggerInfo.
//
// The ITypes.sol TriggerInfo struct is:
//
//	struct TriggerInfo { uint64 triggerId; address creator; bytes data; }
//
// Packed inside the NewTrigger event as: abi.encode(TriggerInfo)
// wrapped in another abi.encode(_triggerInfo bytes) for the event topic.
//
// Manual ABI decoding (no cgo, no reflection — pure Go, TinyGo-compatible):
//   - Outer event data: 32-byte offset + 32-byte length + N bytes of TriggerInfo abi bytes
//   - Inner TriggerInfo: triggerId (32B, uint64 in low 8B), creator (32B, address in low 20B), data offset+length+bytes
func decodeTriggerInfo(log chainTypes.EvmEventLog) triggerInfo {
	// log.Data.Data is the raw NewTrigger event ABI payload
	raw := log.Data.Data.Slice()

	// The event is: event NewTrigger(bytes _triggerInfo)
	// ABI encoding: offset(32) | length(32) | triggerInfoBytes
	if len(raw) < 96 {
		panic(fmt.Sprintf("event data too short: %d bytes", len(raw)))
	}

	// Offset to _triggerInfo bytes (should be 0x20 = 32)
	// Length of _triggerInfo bytes
	innerLen := binary.BigEndian.Uint64(raw[56:64]) // bytes 56–63 of the 32-byte length word
	innerStart := 64
	if len(raw) < innerStart+int(innerLen) {
		panic(fmt.Sprintf("inner data truncated: need %d, have %d", innerStart+int(innerLen), len(raw)))
	}
	inner := raw[innerStart : innerStart+int(innerLen)]

	// TriggerInfo ABI layout:
	//   [0:32]   triggerId  (uint64, right-aligned)
	//   [32:64]  creator    (address, right-aligned in 32 bytes)
	//   [64:96]  offset to data bytes (= 0x60)
	//   [96:128] length of data bytes
	//   [128..]  data bytes (padded to 32-byte boundary)
	if len(inner) < 128 {
		panic(fmt.Sprintf("trigger info too short: %d bytes", len(inner)))
	}

	triggerID := binary.BigEndian.Uint64(inner[24:32])
	creator := make([]byte, 20)
	copy(creator, inner[44:64]) // low 20 bytes of 32-byte creator word

	dataLen := binary.BigEndian.Uint64(inner[120:128])
	dataStart := 128
	if len(inner) < dataStart+int(dataLen) {
		panic(fmt.Sprintf("trigger data truncated: need %d, have %d", dataStart+int(dataLen), len(inner)))
	}
	data := make([]byte, dataLen)
	copy(data, inner[dataStart:dataStart+int(dataLen)])

	return triggerInfo{TriggerID: triggerID, Creator: creator, Data: data}
}

// encodeOutput ABI-encodes the DataWithId struct for on-chain submission.
//
// Matches ITypes.sol: struct DataWithId { uint64 triggerId; bytes data; }
// ABI layout: triggerId(32B) | offset(32B) | length(32B) | data(padded)
func encodeOutput(triggerID uint64, data []byte) []byte {
	// Encode DataWithId: (uint64 triggerId, bytes data)
	// ABI: [0:32] triggerId | [32:64] offset=0x40 | [64:96] dataLen | [96..] data padded
	dataLen := len(data)
	padLen := (32 - dataLen%32) % 32
	total := 96 + dataLen + padLen

	buf := make([]byte, total)

	// triggerId — uint64 right-aligned in 32 bytes
	binary.BigEndian.PutUint64(buf[24:32], triggerID)

	// offset to data — 0x40 (64)
	binary.BigEndian.PutUint64(buf[56:64], 64)

	// data length
	binary.BigEndian.PutUint64(buf[88:96], uint64(dataLen))

	// data bytes
	copy(buf[96:], data)

	return buf
}

// Ensure cm is used
var _ = cm.None[uint64]()
