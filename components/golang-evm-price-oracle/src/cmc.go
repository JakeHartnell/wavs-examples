package main

import (
	"encoding/json"
	"fmt"
	"math"
	"strings"
)

// cmcRoot is the top-level CoinMarketCap API response.
type cmcRoot struct {
	Status cmcStatus `json:"status"`
	Data   cmcData   `json:"data"`
}

type cmcStatus struct {
	Timestamp string `json:"timestamp"`
}

type cmcData struct {
	Symbol     string        `json:"symbol"`
	Statistics cmcStatistics `json:"statistics"`
}

type cmcStatistics struct {
	Price float64 `json:"price"`
}

// PriceFeedData is the output returned to the chain.
type PriceFeedData struct {
	Symbol    string  `json:"symbol"`
	Price     float64 `json:"price"`
	Timestamp string  `json:"timestamp"`
}

// fetchCryptoPrice fetches the current price of a cryptocurrency by its
// CoinMarketCap ID using the public CMC data API (no API key required).
func fetchCryptoPrice(id int) (*PriceFeedData, error) {
	url := fmt.Sprintf(
		"https://api.coinmarketcap.com/data-api/v3/cryptocurrency/detail?id=%d&range=1h",
		id,
	)

	body, err := httpGet(url)
	if err != nil {
		return nil, fmt.Errorf("GET %s: %w", url, err)
	}

	var root cmcRoot
	if err := json.Unmarshal(body, &root); err != nil {
		return nil, fmt.Errorf("parse JSON: %w", err)
	}

	price := math.Round(root.Data.Statistics.Price*100) / 100
	// Timestamp arrives as "2025-04-30T19:59:44.161Z" — strip sub-seconds
	timestamp := strings.Split(root.Status.Timestamp, ".")[0]

	return &PriceFeedData{
		Symbol:    root.Data.Symbol,
		Price:     price,
		Timestamp: timestamp,
	}, nil
}
