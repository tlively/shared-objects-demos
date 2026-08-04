# Tools (can be set via environment variables, make arguments, or PATH)
EMCC ?= emcc
WASM_OPT ?= wasm-opt
WASM_MERGE ?= wasm-merge
NODE ?= node
PYTHON ?= python3

# Emscripten flags for bootstrapping shared Wasm GC over pthreads
EMCC_FLAGS ?= -pthread -sSHARED_WASMGC -sERROR_ON_UNDEFINED_SYMBOLS=0 \
              -sEXIT_RUNTIME -sPROXY_TO_PTHREAD --js-library libruntime.js

# Binaryen feature flags for shared-everything threads and Wasm GC
WASM_FLAGS ?= --enable-threads --enable-reference-types --enable-gc --enable-shared-everything
WASM_MERGE_FLAGS ?= $(WASM_FLAGS) --skip-export-conflicts
WASM_OPT_FLAGS ?= $(WASM_FLAGS) -O3 --make-shared-objects -O1

BUILD_DIR = build
DEP_DIR = .deps

# Demos list
DEMOS = hello

# Discover .wat source files in demo and runtime directories
WAT_SRCS = $(wildcard $(addsuffix /*.wat,$(DEMOS)) common/*.wat runtime.wat)
DEP_FILES = $(patsubst %.wat,$(DEP_DIR)/%.wat.d,$(WAT_SRCS))

.PHONY: all clean serve $(DEMOS) $(addprefix run-,$(DEMOS))
.SECONDARY:

all: $(DEMOS) index.html

$(BUILD_DIR) $(DEP_DIR):
	mkdir -p $@

# Pattern rule for generating .d dependency files from .wat files (depends on gendep script)
$(DEP_DIR)/%.wat.d: %.wat scripts/gendep.py | $(DEP_DIR)
	@mkdir -p $(dir $@)
	$(PYTHON) scripts/gendep.py $< -o $@

# Single C runtime compiled once for all demos into HTML, JS, and WASM
$(BUILD_DIR)/runtime.wasm $(BUILD_DIR)/runtime.js $(BUILD_DIR)/runtime.html &: runtime.c libruntime.js | $(BUILD_DIR)
	$(EMCC) $(EMCC_FLAGS) $< -o $(BUILD_DIR)/runtime.html

# Merge all WAT dependencies into a bundle and lower shared functions with wasm-opt
$(BUILD_DIR)/%/wat.wasm: %/main.wat
	@mkdir -p $(dir $@)
	$(WASM_MERGE) $(WASM_MERGE_FLAGS) \
		$(foreach f,$(filter %.wat,$^),$(f) $(patsubst %.wat,%,$(f))) \
		-o $@
	$(WASM_OPT) $(WASM_OPT_FLAGS) $@ -o $@

# Link C runtime.wasm with the lowered WAT bundle
$(BUILD_DIR)/%/main.wasm: $(BUILD_DIR)/runtime.wasm $(BUILD_DIR)/%/wat.wasm
	@mkdir -p $(dir $@)
	$(WASM_MERGE) $(WASM_MERGE_FLAGS) \
		$(BUILD_DIR)/runtime.wasm runtime \
		$(BUILD_DIR)/$*/wat.wasm wat \
		-o $@

$(BUILD_DIR)/%/main.js: $(BUILD_DIR)/runtime.js
	@mkdir -p $(dir $@)
	sed 's/runtime\.wasm/main\.wasm/g' $< > $@

$(BUILD_DIR)/%/main.html: $(BUILD_DIR)/runtime.html
	@mkdir -p $(dir $@)
	sed 's/runtime\.js/main\.js/g' $< > $@

# Generic target for building any demo in DEMOS (produces .wasm, .js, and .html)
$(DEMOS): %: $(BUILD_DIR)/%/main.wasm $(BUILD_DIR)/%/main.js $(BUILD_DIR)/%/main.html

# Top-level index.html generated from template
index.html: index.html.in scripts/gen_index.py Makefile
	$(PYTHON) scripts/gen_index.py $< $@ $(DEMOS)

# Generic runner for any demo in DEMOS
$(addprefix run-,$(DEMOS)): run-%: %
	$(NODE) --experimental-wasm-shared $(BUILD_DIR)/$*/main.js

# Build all demos and launch local HTTP server with COOP/COEP headers
serve: all
	$(PYTHON) scripts/serve.py

clean:
	rm -rf $(BUILD_DIR) $(DEP_DIR) index.html

# Include generated .d dependency files
-include $(DEP_FILES)
