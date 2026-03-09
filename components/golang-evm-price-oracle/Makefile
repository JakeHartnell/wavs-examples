WAVS_WIT_PACKAGE ?= ../../compiled/wavs_operator_2_7_0.wasm
WAVS_WIT_WORLD ?= wavs:operator/wavs-world
OUTPUT_DIR ?= ../../compiled

GO ?= go
TINYGO ?= tinygo
WIT_BINDGEN_GO ?= wit-bindgen-go

## wasi-build: build the WASM component from Go source using TinyGo
wasi-build: $(WAVS_WIT_PACKAGE)
	@echo "🔨 Building Go component: golang_evm_price_oracle..."
	@mkdir -p $(OUTPUT_DIR)
	@$(TINYGO) build \
		-target=wasip2 \
		-o $(OUTPUT_DIR)/golang_evm_price_oracle.wasm \
		--wit-package $(WAVS_WIT_PACKAGE) \
		--wit-world "$(WAVS_WIT_WORLD)" \
		./src
	@echo "✅ Built: $(OUTPUT_DIR)/golang_evm_price_oracle.wasm"

## gen-bindings: regenerate Go bindings from WIT (run after WIT changes)
gen-bindings: $(WAVS_WIT_PACKAGE)
	@echo "📝 Regenerating Go bindings from wavs:operator@2.7.0..."
	@rm -rf gen/
	@$(WIT_BINDGEN_GO) generate \
		--world "$(WAVS_WIT_WORLD)" \
		--out ./gen \
		--package-root "github.com/Lay3rLabs/wavs-examples/components/golang-evm-price-oracle/gen" \
		../../wit
	@echo "✅ Bindings regenerated in ./gen"

# Build the WIT package WASM from local WIT files (needed by tinygo --wit-package)
$(WAVS_WIT_PACKAGE):
	@echo "🔧 Building WIT package from local WIT files..."
	@cd ../.. && wkg wit build \
		--wit-dir ./wit \
		-o compiled/wavs_operator_2_7_0.wasm 2>/dev/null || \
	(cp wkg.toml wkg.toml.bak && \
	 cat > wkg.toml << 'WKGEOF' \
[overrides] \
"wavs:types" = { path = "./wit/deps/wavs-types-2.7.0" } \
"wasi:cli" = { path = "./wit/deps/wasi-cli-0.2.0" } \
"wasi:http" = { path = "./wit/deps/wasi-http-0.2.0" } \
"wasi:io" = { path = "./wit/deps/wasi-io-0.2.0" } \
"wasi:clocks" = { path = "./wit/deps/wasi-clocks-0.2.0" } \
"wasi:filesystem" = { path = "./wit/deps/wasi-filesystem-0.2.0" } \
"wasi:random" = { path = "./wit/deps/wasi-random-0.2.0" } \
"wasi:sockets" = { path = "./wit/deps/wasi-sockets-0.2.0" } \
"wasi:keyvalue" = { path = "./wit/deps/wasi-keyvalue-0.2.0-draft2" } \
"wasi:tls" = { path = "./wit/deps/wasi-tls-0.2.0-draft" } \
WKGEOF\
	 wkg wit build --wit-dir ./wit -o compiled/wavs_operator_2_7_0.wasm && \
	 mv wkg.toml.bak wkg.toml)

.PHONY: wasi-build gen-bindings

.PHONY: help
help: Makefile
	@echo
	@echo " Choose a command to run:"
	@echo
	@sed -n 's/^##//p' $< | column -t -s ':' | sed -e 's/^/ /'
	@echo
