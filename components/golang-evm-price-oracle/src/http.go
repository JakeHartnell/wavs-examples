// Package main — raw WASI HTTP client.
//
// Uses the generated wasi:http/outgoing-handler@0.2.0 bindings directly,
// avoiding any third-party HTTP library (which has cm version conflicts with TinyGo).
// This mirrors the approach used in the Rust WAVS components.
package main

import (
	"fmt"
	"strings"

	httphandler "github.com/Lay3rLabs/wavs-examples/components/golang-evm-price-oracle/gen/wasi/http/outgoing-handler"
	httptypes "github.com/Lay3rLabs/wavs-examples/components/golang-evm-price-oracle/gen/wasi/http/types"
	"github.com/Lay3rLabs/wavs-examples/components/golang-evm-price-oracle/gen/wasi/io/poll"
	"go.bytecodealliance.org/cm"
)

// httpGet performs a synchronous HTTP GET and returns the response body.
func httpGet(url string) ([]byte, error) {
	scheme, authority, pathQuery, err := parseURL(url)
	if err != nil {
		return nil, err
	}

	headers := httptypes.NewFields()
	req := httptypes.NewOutgoingRequest(headers)

	req.SetMethod(httptypes.MethodGet())
	req.SetScheme(cm.Some(scheme))
	req.SetAuthority(cm.Some(authority))
	req.SetPathWithQuery(cm.Some(pathQuery))

	// Set Accept header
	acceptKey := httptypes.FieldKey("Accept")
	acceptVal := httptypes.FieldValue(cm.ToList([]byte("application/json")))
	headers.Append(acceptKey, acceptVal)

	result := httphandler.Handle(req, cm.None[httptypes.RequestOptions]())
	if result.IsErr() {
		return nil, fmt.Errorf("HTTP handle: %v", result.Err())
	}

	future := result.OK()
	// wasi:io/poll@0.2.9 replaced pollable.Block() with poll.Poll()
	sub := future.Subscribe()
	poll.Poll(cm.ToList([]poll.Pollable{sub}))
	sub.ResourceDrop()

	getResult := future.Get()
	if getResult.None() {
		return nil, fmt.Errorf("future not ready after block")
	}

	inner := getResult.Some()
	if inner.IsErr() {
		return nil, fmt.Errorf("future error: %v", inner.Err())
	}

	resp := inner.OK()
	if resp.IsErr() {
		return nil, fmt.Errorf("HTTP response error: %v", resp.Err())
	}

	response := resp.OK()
	status := response.Status()
	if status < 200 || status >= 300 {
		return nil, fmt.Errorf("HTTP %d from %s", status, url)
	}

	bodyResult := response.Consume()
	if bodyResult.IsErr() {
		return nil, fmt.Errorf("consume body: %v", bodyResult.Err())
	}
	body := bodyResult.OK()

	streamResult := body.Stream()
	if streamResult.IsErr() {
		return nil, fmt.Errorf("body stream: %v", streamResult.Err())
	}
	stream := streamResult.OK()

	var buf []byte
	emptyReads := 0
	for {
		// wasi:io/poll@0.2.9: use Poll() instead of pollable.Block()
		sub := stream.Subscribe()
		poll.Poll(cm.ToList([]poll.Pollable{sub}))
		sub.ResourceDrop()
		readResult := stream.Read(65536)
		if readResult.IsErr() {
			// StreamErrorClosed = normal end of stream
			break
		}
		chunk := readResult.OK()
		if len(chunk.Slice()) == 0 {
			emptyReads++
			if emptyReads > 32 {
				break
			}
			continue
		}
		buf = append(buf, chunk.Slice()...)
		emptyReads = 0
	}

	// wasi:http@0.2.9: IncomingBody.finish() removed; just drop the resource
	body.ResourceDrop()
	return buf, nil
}

// parseURL splits a URL into (scheme, authority, pathWithQuery).
func parseURL(url string) (httptypes.Scheme, string, string, error) {
	var scheme httptypes.Scheme
	var rest string

	if after, ok := strings.CutPrefix(url, "https://"); ok {
		scheme = httptypes.SchemeHTTPS()
		rest = after
	} else if after, ok := strings.CutPrefix(url, "http://"); ok {
		scheme = httptypes.SchemeHTTP()
		rest = after
	} else {
		return httptypes.Scheme{}, "", "", fmt.Errorf("unsupported URL scheme: %s", url)
	}

	var authority, pathQuery string
	if idx := strings.IndexByte(rest, '/'); idx >= 0 {
		authority = rest[:idx]
		pathQuery = rest[idx:]
	} else {
		authority = rest
		pathQuery = "/"
	}

	return scheme, authority, pathQuery, nil
}
