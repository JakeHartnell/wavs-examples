// Package main is the Go WAVS component: EVM Price Oracle.
//
// Fetches a cryptocurrency price from CoinMarketCap by CMC ID
// and returns it as JSON for on-chain submission.
//
// Demonstrates writing WAVS components in Go using TinyGo's wasip2 target.
// Bindings are generated from the local wavs:operator@2.7.0 WIT world using
// wit-bindgen-go (go.bytecodealliance.org/cmd/wit-bindgen-go).
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	wavsworld "github.com/Lay3rLabs/wavs-examples/components/golang-evm-price-oracle/gen/wavs/operator/wavs-world"
	"go.bytecodealliance.org/cm"
)

func init() {
	wavsworld.Exports.Run = run
}

// run is the main exported function called by the WAVS runtime.
// Signature matches the WIT: run(trigger-action) -> result<list<wasm-response>, string>
func run(action wavsworld.TriggerAction) cm.Result[cm.List[wavsworld.WasmResponse], cm.List[wavsworld.WasmResponse], string] {
	triggerID, input, dest := decodeTriggerEvent(action.Data)

	result, err := compute(input, dest)
	if err != nil {
		return cm.Err[cm.Result[cm.List[wavsworld.WasmResponse], cm.List[wavsworld.WasmResponse], string]](err.Error())
	}

	fmt.Printf("Computation result: %s\n", string(result))

	return routeResult(triggerID, result, dest)
}

// compute fetches the cryptocurrency price for the given CMC ID.
func compute(input []byte, dest destination) ([]byte, error) {
	if dest == destCLI {
		input = bytes.TrimRight(input, "\x00")
	}

	id, err := strconv.Atoi(strings.TrimSpace(string(input)))
	if err != nil {
		return nil, fmt.Errorf("invalid CMC ID %q: %w", string(input), err)
	}

	feed, err := fetchCryptoPrice(id)
	if err != nil {
		return nil, fmt.Errorf("fetch price for ID %d: %w", id, err)
	}

	return json.Marshal(feed)
}

// routeResult wraps the output bytes in a WasmResponse list for the given destination.
func routeResult(triggerID uint64, result []byte, dest destination) cm.Result[cm.List[wavsworld.WasmResponse], cm.List[wavsworld.WasmResponse], string] {
	var response wavsworld.WasmResponse

	switch dest {
	case destCLI:
		response = wavsworld.WasmResponse{
			Payload:     cm.ToList(result),
			Ordering:    cm.None[uint64](),
			EventIDSalt: cm.None[cm.List[uint8]](),
		}
	case destEthereum:
		encoded := encodeOutput(triggerID, result)
		fmt.Printf("ABI-encoded output (hex): %x\n", encoded)
		response = wavsworld.WasmResponse{
			Payload:     cm.ToList(encoded),
			Ordering:    cm.None[uint64](),
			EventIDSalt: cm.None[cm.List[uint8]](),
		}
	default:
		return cm.Err[cm.Result[cm.List[wavsworld.WasmResponse], cm.List[wavsworld.WasmResponse], string]](
			fmt.Sprintf("unsupported destination: %v", dest),
		)
	}

	responses := []wavsworld.WasmResponse{response}
	return cm.OK[cm.Result[cm.List[wavsworld.WasmResponse], cm.List[wavsworld.WasmResponse], string]](cm.ToList(responses))
}

// empty main to satisfy the wasm-ld linker (WIT export-only component)
func main() {}
