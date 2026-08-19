# Tools (can be set via environment variables, make arguments, or PATH)
WASM_OPT ?= wasm-opt
WASM_MERGE ?= wasm-merge
PYTHON ?= python3

# Binaryen feature flags for shared-everything threads and Wasm GC
WASM_FLAGS ?= --enable-threads --enable-reference-types --enable-gc --enable-shared-everything
WASM_MERGE_FLAGS ?= $(WASM_FLAGS) --skip-export-conflicts
WASM_OPT_FLAGS ?= $(WASM_FLAGS) -O3 --make-shared-objects -O1

BUILD_DIR = build
DEP_DIR = .deps

# Demos list
DEMOS = hello philosophers workqueue

# Discover .wat source files in demo and runtime directories
WAT_SRCS = $(wildcard $(addsuffix /*.wat,$(DEMOS)) common/*.wat runtime.wat)
DEP_FILES = $(patsubst %.wat,$(DEP_DIR)/%.wat.d,$(WAT_SRCS))

.PHONY: all clean serve $(DEMOS)
.SECONDARY:

all: $(DEMOS) index.html

$(BUILD_DIR) $(DEP_DIR):
	mkdir -p $@

# Pattern rule for generating .d dependency files from .wat files
$(DEP_DIR)/%.wat.d: %.wat scripts/gendep.py | $(DEP_DIR)
	@mkdir -p $(dir $@)
	$(PYTHON) scripts/gendep.py $< -o $@

# Merge all WAT dependencies into main.wasm and lower shared objects with wasm-opt
$(BUILD_DIR)/%/main.wasm: %/main.wat
	@mkdir -p $(dir $@)
	$(WASM_MERGE) $(WASM_MERGE_FLAGS) \
		$(foreach f,$(filter-out $<,$(filter %.wat,$^)) $<,$(f) $(patsubst %.wat,%,$(f))) \
		-o $@
	$(WASM_OPT) $(WASM_OPT_FLAGS) $@ -o $@

# Copy runtime.js into the demo build directory
$(BUILD_DIR)/%/runtime.js: runtime.js
	@mkdir -p $(dir $@)
	cp $< $@

# Generate HTML shell for each demo
$(BUILD_DIR)/%/main.html: default_template.html
	@mkdir -p $(dir $@)
	@if [ -f $*/template.html ]; then \
		cp $*/template.html $@; \
	else \
		sed 's/Shared Wasm GC Demo/Shared Wasm GC - $* Demo/g' default_template.html > $@; \
	fi

# Target for building any demo in DEMOS (produces .wasm, runtime.js, and .html)
$(DEMOS): %: $(BUILD_DIR)/%/main.wasm $(BUILD_DIR)/%/runtime.js $(BUILD_DIR)/%/main.html

# Top-level index.html generated from template
index.html: index.html.in scripts/gen_index.py Makefile
	$(PYTHON) scripts/gen_index.py $< $@ $(DEMOS)

# Build all demos and launch local HTTP server with COOP/COEP headers
serve: all
	$(PYTHON) scripts/serve.py

clean:
	rm -rf $(BUILD_DIR) $(DEP_DIR) index.html

# Include generated .d dependency files
-include $(DEP_FILES)
