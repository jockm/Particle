# ==============================================================================
# Makefile - Particle & Parcore Master Build and Test Automation
# ==============================================================================

SHELL        := /bin/bash
DART         ?= dart

PYTHON       ?= python3

PBUILD       := ./pbuild

# ------------------------------------------------------------------------------
# Simulator Selection
# ------------------------------------------------------------------------------
# Default: Python reference simulator (tools/psim.py)
# To switch to compiled native Dart simulator, comment out this line and uncomment
# the Dart definition below:
PSIM         := build/tools/psim
# PSIM         := build/tools/psim

ROHD_DIR     := hdl/particle
PARCORE_DIR  := hdl/parcore
BUILD_DIR    := build
TOOL_DIR     := apps/tools
TOOL_BIN_DIR := $(BUILD_DIR)/tools
PASM_LINT_BIN:= $(TOOL_BIN_DIR)/pasm_lint
PASM_BIN     := $(TOOL_BIN_DIR)/pasm
PARCORE_BLD  := $(BUILD_DIR)/parcore

# Recursive wildcard across firmware/parcore
FIRMWARE_SRCS := $(shell find firmware/parcore -name '*.asm' 2>/dev/null)
FIRMWARE_BINS := $(patsubst firmware/parcore/%.asm,$(PARCORE_BLD)/%.bin,$(FIRMWARE_SRCS))

APP_ASM_SRCS  := $(wildcard apps/asm/*.asm)
APP_ASM_BINS  := $(patsubst apps/asm/%.asm,$(BUILD_DIR)/%.bin,$(APP_ASM_SRCS))

APP_ACT_SRCS  := $(wildcard apps/act16/*.act)
APP_ACT_BINS  := $(patsubst apps/act16/%.act,$(BUILD_DIR)/%.bin,$(APP_ACT_SRCS))

.PHONY: all setup test test-all test-particle test-parcore test-sim compiler-tests test-lint \
        lint lint-asm build generate generate-particle generate-parcore \
        firmware apps clean help

# ------------------------------------------------------------------------------
# Top-Level Targets
# ------------------------------------------------------------------------------

all: build test

help:
	@echo "Particle & Parcore Build Automation"
	@echo "==================================="
	@echo "  make setup            - Fetch Dart dependencies for hdl/particle and parcore"
	@echo "  make lint-asm         - Statically lint all assembly files"
	@echo "  make build            - Build firmware, apps, and generate all HDL"
	@echo "  make test             - Run all unit and integration tests (ROHD + Sim)"
	@echo "  make test-particle    - Run Particle single-core ROHD tests"
	@echo "  make test-parcore     - Run Parcore multi-core ROHD tests"
	@echo "  make test-sim         - Run instruction simulator verification"
	@echo "  make compiler-tests   - Run all ACT16 compiler test suites in psim"
	@echo "  make generate         - Generate synthesizable SystemVerilog (.sv)"
	@echo "  make firmware         - Assemble all Parcore pipeline microkernels"
	@echo "  make apps             - Build ACT16 and ASM application binaries"
	@echo "  make clean            - Remove all build artifacts and generated SV"

setup:
	@echo "==> Fetching dependencies for Particle ROHD..."
	@cd $(ROHD_DIR) && $(DART) pub get
	@echo "==> Fetching dependencies for Parcore ROHD..."
	@cd $(PARCORE_DIR) && $(DART) pub get

# ------------------------------------------------------------------------------
# Linting Targets
# ------------------------------------------------------------------------------

lint: lint-asm

lint-asm:
	@echo "==> Linting Parcore firmware sources..."
	@for f in $(FIRMWARE_SRCS); do $(PYTHON) tools/pasm_lint.py "$$f" || exit 1; done
	@echo "==> Linting ASM application sources..."
	@for f in $(APP_ASM_SRCS); do $(PYTHON) tools/pasm_lint.py "$$f" || exit 1; done

# ------------------------------------------------------------------------------
# Generation Targets (SystemVerilog)
# ------------------------------------------------------------------------------

generate: generate-particle generate-parcore

generate-particle: setup
	@echo "==> Generating Particle SystemVerilog (particle_top.sv)..."
	@cd $(ROHD_DIR) && $(DART) run bin/generate.dart

generate-parcore: setup
	@echo "==> Generating Parcore SystemVerilog (parcore_top.sv)..."
	@cd $(PARCORE_DIR) && $(DART) run bin/generate_parcore.dart

# ------------------------------------------------------------------------------
# Verification & Test Suites
# ------------------------------------------------------------------------------

test: test-particle test-parcore test-sim

test-particle: setup
	@echo "==> Running Particle single-core ROHD tests..."
	@cd $(ROHD_DIR) && $(DART) test

test-parcore: setup
	@echo "==> Running Parcore RV32IM pipeline regression suite..."
	@cd $(PARCORE_DIR) && ./test_pipeline.sh

# Run instruction-level simulation tests.
# Uses $(PSIM) as defined above (currently tools/psim.py).
# To test compiled Dart instead: make psim && build/tools/psim $(BUILD_DIR)/branch_suite.bin
test-sim: $(BUILD_DIR)/branch_suite.bin
	@echo "==> Running instruction-level simulation tests ($(PSIM))..."
	$(PSIM) $(BUILD_DIR)/branch_suite.bin

	@echo "==> Running instruction-level simulation tests (build/tools/psim)..."
	build/tools/psim $(BUILD_DIR)/branch_suite.bin

ACT_TEST_SRCS := $(wildcard apps/act16/*_test.act)

compiler-tests:
	@mkdir -p $(BUILD_DIR)
	@echo "==> Building and running ACT16 compiler test suites..."
	@failed=0; \
	for src in $(ACT_TEST_SRCS); do \
		base=$$(basename "$$src" .act); \
		bin="$(BUILD_DIR)/$${base}.bin"; \
		echo "----------------------------------------------------------------"; \
		echo "Testing: $$src -> $$bin"; \
		$(PBUILD) "$$src" -o "$$bin" || { echo "[FAIL] Build failed for $$src"; failed=1; break; }; \
		$(PSIM) "$$bin" || { echo "[FAIL] $$bin failed simulation"; failed=1; break; }; \
	done; \
	if [ $$failed -ne 0 ]; then \
		echo "==> [FAIL] ACT16 compiler tests failed."; \
		exit 1; \
	else \
		echo "==> [PASS] All ACT16 compiler tests passed successfully."; \
	fi

# ------------------------------------------------------------------------------
# Linter Test Suite (pasm_lint)
# ------------------------------------------------------------------------------
LINT_FAIL_SRCS := $(wildcard apps/asm/lint_failures/*.asm)

test-lint: pasm-lint
	@echo "==> Running pasm_lint test suite..."
	@echo "  -> Validating production assembly sources (must pass)..."
	@for f in apps/asm/*.asm; do \
		build/tools/pasm_lint "$$f" -I lib > /dev/null || { echo "[FAIL] Unexpected lint failure on valid file: $$f"; exit 1; }; \
	done
	@echo "  -> Validating negative fixture constraints (must fail)..."
	@for f in $(LINT_FAIL_SRCS); do \
		if build/tools/pasm_lint "$$f" -I lib > /dev/null 2>&1; then \
			echo "[FAIL] Expected lint violation not detected for: $$f"; \
			exit 1; \
		fi; \
	done
	@echo "==> [PASS] All positive and negative pasm_lint tests passed successfully."

# ------------------------------------------------------------------------------
# Firmware & Application Targets (via pbuild)
# ------------------------------------------------------------------------------

build: firmware apps

firmware: $(FIRMWARE_BINS)

$(PARCORE_BLD)/%.bin: firmware/parcore/%.asm
	@mkdir -p $(dir $@)
	@$(PBUILD) "$<" -o "$@"

apps: $(APP_ASM_BINS) $(APP_ACT_BINS)

$(BUILD_DIR)/branch_suite.bin: apps/asm/branch_suite.asm
	@mkdir -p $(BUILD_DIR)
	@$(PBUILD) "$<" -o "$@"

$(BUILD_DIR)/%.bin: apps/asm/%.asm
	@mkdir -p $(BUILD_DIR)
	@$(PBUILD) "$<" -o "$@"

$(BUILD_DIR)/%.bin: apps/act16/%.act
	@mkdir -p $(BUILD_DIR)
	@$(PBUILD) "$<" -o "$@" 
$(BUILD_DIR):
	@mkdir -p $@

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------





# ------------------------------------------------------------------------------
# Toolchain Targets
# ------------------------------------------------------------------------------
.PHONY: tools pasm-lint psim pasm lint-tool

tools: pasm-lint pasm psim

lint-tool: pasm-lint
pasm-lint: $(PASM_LINT_BIN)

$(PASM_LINT_BIN): $(shell find apps/tools/pasm_lint -name "*.dart" 2>/dev/null) | $(TOOL_BIN_DIR)
	@echo "==> Compiling pasm_lint..."
	@cd apps/tools/pasm_lint && $(DART) pub get > /dev/null
	@$(DART) compile exe apps/tools/pasm_lint/bin/main.dart -o $@

pasm: $(PASM_BIN)

$(PASM_BIN): $(shell find apps/tools/pasm -name "*.dart" 2>/dev/null) | $(TOOL_BIN_DIR)
	@echo "==> Compiling pasm..."
	@cd apps/tools/pasm && $(DART) pub get > /dev/null
	@$(DART) compile exe apps/tools/pasm/bin/main.dart -o $@

$(TOOL_BIN_DIR):
	@mkdir -p $@

clean:
	@echo "==> Cleaning build artifacts and generated SV files..."
	@rm -rf $(BUILD_DIR)
	@rm -rf $(ROHD_DIR)/.dart_tool $(ROHD_DIR)/particle_top.sv $(ROHD_DIR)/*.synth.json $(ROHD_DIR)/*.bit
	@rm -rf $(PARCORE_DIR)/.dart_tool $(PARCORE_DIR)/parcore_top.sv $(PARCORE_DIR)/*.synth.json $(PARCORE_DIR)/*.bit

psim: $(BUILD_DIR)/tools/psim

$(BUILD_DIR)/tools/psim: apps/tools/psim/bin/main.dart apps/tools/psim/lib/core.dart apps/tools/psim/lib/line_reader.dart
	@mkdir -p $(BUILD_DIR)/tools
	@echo "==> Compiling psim..."
	dart compile exe apps/tools/psim/bin/main.dart -o $(BUILD_DIR)/tools/psim

# --- Guest RV32 Test Program Targets ---
GUEST_GEN_DIR := apps/asm/gen
GUEST_TEST_BIN := build/guest_rv32_test.bin

$(GUEST_TEST_BIN): $(GUEST_GEN_DIR)/gen_guest_rv32.py
	mkdir -p build
	python3 $(GUEST_GEN_DIR)/gen_guest_rv32.py

guest-tests: $(GUEST_TEST_BIN)

.PHONY: guest-tests
