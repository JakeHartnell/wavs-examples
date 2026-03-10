WAVS_WIT_PACKAGE ?= wavs_operator_2_7_0.wasm
WAVS_WIT_WORLD ?= wavs:operator/wavs-world
OUTPUT_DIR ?= ../../compiled

## wasi-build: build the WASM component from TypeScript using componentize-js
wasi-build: $(WAVS_WIT_PACKAGE) node_modules
	@echo "🔨 Building JS/TS component: js_evm_price_oracle..."
	@mkdir -p $(OUTPUT_DIR)
	@# 1. Generate TypeScript type bindings from WIT
	@npx jco types $(WAVS_WIT_PACKAGE) --out-dir out/
	@# 2. Compile TypeScript → JavaScript
	@npx tsc --outDir out/ index.ts \
		--target ES2020 --module ES2020 --moduleResolution bundler \
		--strict --skipLibCheck true
	@# 3. Bundle to a single ESM file
	@# viem's ABI functions are pure math — no crypto deps, no polyfill needed
	@npx esbuild ./out/index.js \
		--bundle \
		--outfile=out/out.js \
		--platform=node \
		--format=esm \
		--tree-shaking=true
	@# 4. Componentize: JS + WIT → WASM component
	@npx jco componentize out/out.js \
		--wit $(WAVS_WIT_PACKAGE:.wasm=.wit) \
		--world-name "$(WAVS_WIT_WORLD)" \
		--out $(OUTPUT_DIR)/js_evm_price_oracle.wasm
	@echo "✅ Built: $(OUTPUT_DIR)/js_evm_price_oracle.wasm"

## build-wit: generate WIT package WASM + WIT text from local WIT files
build-wit:
	@echo "🔧 Building WIT package from local WIT files..."
	@cd ../.. && wkg wit build --wit-dir ./wit -o components/js-evm-price-oracle/$(WAVS_WIT_PACKAGE) 2>/dev/null || \
	(cp wkg.toml wkg.toml.bak && \
	 python3 -c "import subprocess; open('wkg.toml','w').write(open('wkg.toml').read() + \"\n[overrides]\n\\\"wavs:types\\\" = { path = \\\"./wit/deps/wavs-types-2.7.0\\\" }\n\\\"wasi:cli\\\" = { path = \\\"./wit/deps/wasi-cli-0.2.0\\\" }\n\\\"wasi:http\\\" = { path = \\\"./wit/deps/wasi-http-0.2.0\\\" }\n\\\"wasi:io\\\" = { path = \\\"./wit/deps/wasi-io-0.2.0\\\" }\n\\\"wasi:clocks\\\" = { path = \\\"./wit/deps/wasi-clocks-0.2.0\\\" }\n\\\"wasi:filesystem\\\" = { path = \\\"./wit/deps/wasi-filesystem-0.2.0\\\" }\n\\\"wasi:random\\\" = { path = \\\"./wit/deps/wasi-random-0.2.0\\\" }\n\\\"wasi:sockets\\\" = { path = \\\"./wit/deps/wasi-sockets-0.2.0\\\" }\n\\\"wasi:keyvalue\\\" = { path = \\\"./wit/deps/wasi-keyvalue-0.2.0-draft2\\\" }\n\\\"wasi:tls\\\" = { path = \\\"./wit/deps/wasi-tls-0.2.0-draft\\\" }\")" && \
	 wkg wit build --wit-dir ./wit -o components/js-evm-price-oracle/$(WAVS_WIT_PACKAGE) && \
	 mv wkg.toml.bak wkg.toml)
	@wasm-tools component wit $(WAVS_WIT_PACKAGE) -o $(WAVS_WIT_PACKAGE:.wasm=.wit)
	@echo "✅ WIT package ready"

$(WAVS_WIT_PACKAGE):
	@$(MAKE) build-wit

node_modules:
	@npm install --include=dev

.PHONY: wasi-build build-wit

.PHONY: help
help: Makefile
	@echo
	@echo " Choose a command to run:"
	@echo
	@sed -n 's/^##//p' $< | column -t -s ':' | sed -e 's/^/ /'
	@echo
