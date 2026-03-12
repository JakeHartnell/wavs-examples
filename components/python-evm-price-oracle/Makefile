WIT_DIR         ?= ./wit-clean
WAVS_WIT_WORLD  ?= wavs:operator/wavs-world
OUTPUT_DIR      ?= ../../compiled
COMPONENTIZE_PY ?= componentize-py

# Try common install paths if not on PATH
COMPONENTIZE_PY_BIN := $(shell which $(COMPONENTIZE_PY) 2>/dev/null || echo /home/node/.local/bin/componentize-py)

## wasi-build: compile Python component → WASM using componentize-py
wasi-build:
	@echo "🐍 Building Python component: python_evm_price_oracle..."
	@$(COMPONENTIZE_PY_BIN) --version > /dev/null 2>&1 || \
		(echo "❌ componentize-py not found. Install with:" && \
		 echo "   curl https://bootstrap.pypa.io/get-pip.py | python3 - --user --break-system-packages" && \
		 echo "   pip install componentize-py==0.21.0 --user --break-system-packages" && exit 1)
	@mkdir -p $(OUTPUT_DIR)
	@$(COMPONENTIZE_PY_BIN) \
		-d $(WIT_DIR) \
		-w $(WAVS_WIT_WORLD) \
		componentize component \
		-o /tmp/python_evm_price_oracle_unstripped.wasm
	@echo "🔪 Stripping debug info (reduces ~41MB → ~19MB)..."
	@wasm-tools strip /tmp/python_evm_price_oracle_unstripped.wasm \
		-o $(OUTPUT_DIR)/python_evm_price_oracle.wasm
	@echo "✅ Built: $(OUTPUT_DIR)/python_evm_price_oracle.wasm"
	@ls -lh $(OUTPUT_DIR)/python_evm_price_oracle.wasm

## gen-bindings: generate Python type stubs from WIT (IDE support / inspection)
gen-bindings:
	@echo "📝 Generating Python bindings from wavs:operator@2.7.0..."
	@rm -rf wavs_guest/
	@$(COMPONENTIZE_PY_BIN) -d $(WIT_DIR) -w $(WAVS_WIT_WORLD) bindings wavs_guest
	@echo "✅ Bindings generated in wavs_guest/ (not committed)"

## install-deps: install componentize-py (one-time setup)
install-deps:
	@echo "📦 Installing componentize-py..."
	@curl -s https://bootstrap.pypa.io/get-pip.py | python3 - --user --break-system-packages
	@/home/node/.local/bin/pip install componentize-py==0.21.0 --user --break-system-packages
	@echo "✅ componentize-py installed"

.PHONY: wasi-build gen-bindings install-deps

.PHONY: help
help: Makefile
	@echo
	@echo " Choose a command to run:"
	@echo
	@sed -n 's/^##//p' $< | column -t -s ':' | sed -e 's/^/ /'
	@echo
