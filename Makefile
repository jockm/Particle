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
# Compiled Dart simulator (build it with 'make psim')
PSIM         := build/tools/psim

ROHD_DIR     := hdl/particle
PARCORE_DIR  := hdl/parcore
BUILD_DIR    := build
TOOL_DIR     := apps/tools
TOOL_BIN_DIR := $(BUILD_DIR)/tools
PASM_LINT_BIN:= $(TOOL_BIN_DIR)/pasm_lint
PASM_LSP_BIN := $(TOOL_BIN_DIR)/pasm_lsp
PASM_BIN     := $(TOOL_BIN_DIR)/pasm
ACTION_BIN   := $(TOOL_BIN_DIR)/action
PARCORE_BLD  := $(BUILD_DIR)/parcore

# Recursive wildcard across firmware/parcore
FIRMWARE_SRCS := $(shell find firmware/parcore -name '*.asm' 2>/dev/null)
FIRMWARE_BINS := $(patsubst firmware/parcore/%.asm,$(PARCORE_BLD)/%.bin,$(FIRMWARE_SRCS))

APP_ASM_SRCS  := $(wildcard apps/asm/*.asm)
APP_ASM_BINS  := $(patsubst apps/asm/%.asm,$(BUILD_DIR)/%.bin,$(APP_ASM_SRCS))

# heap_after_asm_main.act needs its .asm library; compiler-tests builds the pair
APP_ACT_SRCS  := $(filter-out apps/act/heap_after_asm_main.act,$(wildcard apps/act/*.act))
APP_ACT_BINS  := $(patsubst apps/act/%.act,$(BUILD_DIR)/%.bin,$(APP_ACT_SRCS))

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
	@echo "  make compiler-tests   - Run Action compiler unit tests and all test suites in psim"
	@echo "  make action           - Build the Action compiler (build/tools/action)"
	@echo "  make generate         - Generate synthesizable SystemVerilog (.sv)"
	@echo "  make firmware         - Assemble all Parcore pipeline microkernels"
	@echo "  make apps             - Build Action and ASM application binaries"
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

lint-asm: $(PASM_LINT_BIN)
	@echo "==> Linting Parcore firmware sources..."
	@for f in $(FIRMWARE_SRCS); do $(PASM_LINT_BIN) "$$f" || exit 1; done
	@echo "==> Linting ASM application sources..."
	@for f in $(APP_ASM_SRCS); do $(PASM_LINT_BIN) "$$f" || exit 1; done

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

# Run instruction-level simulation tests with $(PSIM) (build/tools/psim).
test-sim: $(BUILD_DIR)/branch_suite.bin
	@echo "==> Running instruction-level simulation tests ($(PSIM))..."
	$(PSIM) $(BUILD_DIR)/branch_suite.bin

	@echo "==> Running instruction-level simulation tests (build/tools/psim)..."
	build/tools/psim $(BUILD_DIR)/branch_suite.bin

# Tests that must end in a trap other than trap 0. For now each must stop
# with trap 15 at one of the compiler's checks: by default a bounds check;
# a test whose source has a line "// Must stop at: <text>" must stop at the
# check whose .asm line contains <text>.
ACT_TRAP_TESTS := apps/act/test_dyn_bounds_fail.act \
                  apps/act/test_fixed_bounds_fail.act \
                  apps/act/test_open_bounds_fail.act \
                  apps/act/test_null_global_fail.act \
                  apps/act/test_global_heap_bounds_fail.act \
                  apps/act/test_field_bounds_fail.act \
                  apps/act/test_field_null_fail.act
ACT_TEST_SRCS := $(filter-out $(ACT_TRAP_TESTS),$(wildcard apps/act/test_*.act))

compiler-tests: $(ACTION_BIN) $(PASM_BIN) $(PASM_LINT_BIN) psim
	@mkdir -p $(BUILD_DIR)
	@echo "==> Running Action compiler unit tests..."
	@cd apps/tools/action && $(DART) test
	@echo "==> Building and running Action compiler test suites..."
	@failed=0; \
	sim_result() { \
		code=$$1; \
		if [ $$code -eq 15 ]; then echo "[FAIL] test failed (trap 15)"; \
		elif [ $$code -gt 15 ]; then echo "[FAIL] some other error occurred (exit $$code)"; \
		elif [ $$code -ne 0 ]; then echo "[FAIL] unexpected exit $$code"; fi; \
	}; \
	trap_check() { \
		out=$$($(PSIM) "$$1"); code=$$?; echo "$$out"; \
		if [ $$code -ne 15 ]; then echo "[FAIL] expected trap 15 from a '$$4' check, got exit $$code"; return 1; fi; \
		pc=$$(echo "$$out" | sed -n 's/.*Trap 15 triggered at PC: 0x\([0-9A-Fa-f]*\).*/\1/p' | head -1); \
		addr=$$(printf '%08X' $$((0x$$pc - 2))); \
		line=$$(awk -v a="$$addr" '$$1 == a { print $$3; exit }' "$$2"); \
		if [ -z "$$line" ] || ! sed -n "$${line}p" "$$3" | grep -qF "$$4"; then \
			echo "[FAIL] trap 15 at 0x$$addr is not a '$$4' check"; return 1; fi; \
	}; \
	for src in $(ACT_TEST_SRCS); do \
		base=$$(basename "$$src" .act); \
		bin="$(BUILD_DIR)/$${base}.bin"; \
		echo "----------------------------------------------------------------"; \
		echo "Testing: $$src -> $$bin"; \
		$(PBUILD) "$$src" -o "$$bin" || { echo "[FAIL] Build failed for $$src"; failed=1; break; }; \
		$(PSIM) "$$bin" || { code=$$?; echo "[FAIL] $$bin failed simulation"; sim_result $$code; failed=1; break; }; \
	done; \
	if [ $$failed -eq 0 ]; then \
		for src in $(ACT_TRAP_TESTS); do \
			base=$$(basename "$$src" .act); \
			bin="$(BUILD_DIR)/$${base}.bin"; \
			echo "----------------------------------------------------------------"; \
			marker=$$(sed -n 's|^// Must stop at: ||p' "$$src" | head -1); \
			[ -n "$$marker" ] || marker="out-of-bounds trap"; \
			echo "Testing (must stop with trap 15 at a '$$marker' check): $$src -> $$bin"; \
			$(PBUILD) "$$src" -o "$$bin" || { echo "[FAIL] Build failed for $$src"; failed=1; break; }; \
			trap_check "$$bin" "$(BUILD_DIR)/$${base}.lst" "$(BUILD_DIR)/$${base}.asm" "$$marker" || { echo "[FAIL] $$bin failed simulation"; failed=1; break; }; \
		done; \
	fi; \
	if [ $$failed -eq 0 ]; then \
		echo "----------------------------------------------------------------"; \
		echo "Testing Multi-File Action: apps/act/multi_file_main.act apps/act/multi_file_math.act -> $(BUILD_DIR)/multi_file_test.bin"; \
		$(PBUILD) apps/act/multi_file_main.act apps/act/multi_file_math.act -o "$(BUILD_DIR)/multi_file_test.bin" || { echo "[FAIL] Build failed for multi-file Action test"; failed=1; }; \
		$(PSIM) "$(BUILD_DIR)/multi_file_test.bin" || { code=$$?; echo "[FAIL] multi_file_test.bin failed simulation"; sim_result $$code; failed=1; }; \
	fi; \
	if [ $$failed -eq 0 ]; then \
		echo "----------------------------------------------------------------"; \
		echo "Testing Action with an assembly library: apps/act/heap_after_asm_main.act apps/act/heap_after_asm_lib.asm -> $(BUILD_DIR)/heap_after_asm_test.bin"; \
		$(PBUILD) apps/act/heap_after_asm_main.act apps/act/heap_after_asm_lib.asm -o "$(BUILD_DIR)/heap_after_asm_test.bin" || { echo "[FAIL] Build failed for Action with an assembly library"; failed=1; }; \
		$(PSIM) "$(BUILD_DIR)/heap_after_asm_test.bin" || { code=$$?; echo "[FAIL] heap_after_asm_test.bin failed simulation"; sim_result $$code; failed=1; }; \
	fi; \
	if [ $$failed -ne 0 ]; then \
		echo "==> [FAIL] Action compiler tests failed."; \
		exit 1; \
	else \
		echo "==> Running Action negative & semantic diagnostic tests..."; \
		$(PYTHON) apps/tools/test_tuple_diagnostics.py || { echo "[FAIL] Negative diagnostic tests failed."; exit 1; }; \
		echo "==> [PASS] All Action compiler tests passed successfully."; \
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

$(BUILD_DIR)/%.bin: apps/act/%.act $(ACTION_BIN)
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
.PHONY: tools pasm-lint pasm-lsp psim pasm action lint-tool

tools: pasm-lint pasm-lsp pasm psim action

lint-tool: pasm-lint
pasm-lint: $(PASM_LINT_BIN)

$(PASM_LINT_BIN): $(shell find apps/tools/pasm_lint -name "*.dart" 2>/dev/null) | $(TOOL_BIN_DIR)
	@echo "==> Compiling pasm_lint..."
	@cd apps/tools/pasm_lint && $(DART) pub get > /dev/null
	@$(DART) compile exe apps/tools/pasm_lint/bin/main.dart -o $@

pasm-lsp: $(PASM_LSP_BIN)

$(PASM_LSP_BIN): $(shell find apps/tools/pasm_lsp -name "*.dart" 2>/dev/null) $(shell find apps/tools/pasm -name "*.dart" 2>/dev/null) $(shell find apps/tools/pasm_lint -name "*.dart" 2>/dev/null) | $(TOOL_BIN_DIR)
	@echo "==> Compiling pasm_lsp..."
	@cd apps/tools/pasm_lsp && $(DART) pub get > /dev/null
	@$(DART) compile exe apps/tools/pasm_lsp/bin/main.dart -o $@

pasm: $(PASM_BIN)

$(PASM_BIN): $(shell find apps/tools/pasm -name "*.dart" 2>/dev/null) | $(TOOL_BIN_DIR)
	@echo "==> Compiling pasm..."
	@cd apps/tools/pasm && $(DART) pub get > /dev/null
	@$(DART) compile exe apps/tools/pasm/bin/main.dart -o $@

action: $(ACTION_BIN)

$(ACTION_BIN): $(shell find apps/tools/action -name "*.dart" 2>/dev/null) apps/tools/action/pubspec.yaml | $(TOOL_BIN_DIR)
	@echo "==> Compiling action..."
	@cd apps/tools/action && $(DART) pub get > /dev/null
	@$(DART) compile exe apps/tools/action/bin/main.dart -o $@

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
	$(DART) compile exe apps/tools/psim/bin/main.dart -o $(BUILD_DIR)/tools/psim

# --- Guest RV32 Test Program Targets ---
GUEST_GEN_DIR := apps/asm/gen
GUEST_TEST_BIN := build/guest_rv32_test.bin

$(GUEST_TEST_BIN): $(GUEST_GEN_DIR)/gen_guest_rv32.py
	mkdir -p build
	python3 $(GUEST_GEN_DIR)/gen_guest_rv32.py

guest-tests: $(GUEST_TEST_BIN)

.PHONY: guest-tests
