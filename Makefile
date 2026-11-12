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
ACTION_LSP_BIN := $(TOOL_BIN_DIR)/action_lsp
VSCODE_DIR   := apps/tools/vscode
VSCODE_EXTS  := action particle

# macOS writes ._ metadata files on non-Apple file systems (such as exFAT).
# Where dot_clean exists, the targets that write files run it over the
# project afterwards; elsewhere this does nothing. It runs only for the
# targets named on the command line (or 'all'), so a target such as 'tools'
# cleans once at the end rather than once for each tool it builds.
DOT_CLEAN    := $(shell command -v dot_clean 2>/dev/null)
DOT_CLEAN_CMD = $(if $(and $(DOT_CLEAN),$(filter $@,$(or $(MAKECMDGOALS),all))),$(DOT_CLEAN) "$(CURDIR)" > /dev/null 2>&1 || true,true)
# The VS Code command line: 'code' on PATH, or inside the macOS app bundle
VSCODE_CLI   := $(shell command -v code 2>/dev/null || { p="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"; [ -x "$$p" ] && echo "$$p"; })
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
	@$(DOT_CLEAN_CMD)

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
	@echo "  make action-lsp       - Build the Action language server (build/tools/action_lsp)"
	@echo "  make vscode-ext       - Package the VS Code extensions (build/action.vsix, build/particle.vsix; needs npm)"
	@echo "  make vscode-install   - Build the language servers and extensions, and install the extensions in VS Code"
	@echo "  make vscode-remove-old-pasm - Remove the old hand-installed pasm extension"
	@echo "  make generate         - Generate synthesizable SystemVerilog (.sv)"
	@echo "  make firmware         - Assemble all Parcore pipeline microkernels"
	@echo "  make apps             - Build Action and ASM application binaries"
	@echo "  make clean            - Remove all build artifacts and generated SV"
	@echo "  make dot-clean        - Remove macOS ._ metadata files (where dot_clean exists)"

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
	@$(DOT_CLEAN_CMD)

# ------------------------------------------------------------------------------
# Generation Targets (SystemVerilog)
# ------------------------------------------------------------------------------

generate: generate-particle generate-parcore
	@$(DOT_CLEAN_CMD)

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
	@$(DOT_CLEAN_CMD)

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
	@$(DOT_CLEAN_CMD)

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
	@echo "==> Running Action language server tests..."
	@cd apps/tools/action_lsp && $(DART) pub get > /dev/null && $(DART) test
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
	@$(DOT_CLEAN_CMD)

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
	@$(DOT_CLEAN_CMD)

# ------------------------------------------------------------------------------
# Firmware & Application Targets (via pbuild)
# ------------------------------------------------------------------------------

build: firmware apps

firmware: $(FIRMWARE_BINS)
	@$(DOT_CLEAN_CMD)

$(PARCORE_BLD)/%.bin: firmware/parcore/%.asm
	@mkdir -p $(dir $@)
	@$(PBUILD) "$<" -o "$@"

apps: $(APP_ASM_BINS) $(APP_ACT_BINS)
	@$(DOT_CLEAN_CMD)

$(BUILD_DIR)/branch_suite.bin: apps/asm/branch_suite.asm
	@mkdir -p $(BUILD_DIR)
	@$(PBUILD) "$<" -o "$@"

$(BUILD_DIR)/%.bin: apps/asm/%.asm
	@mkdir -p $(BUILD_DIR)
	@$(PBUILD) "$<" -o "$@"

$(BUILD_DIR)/%.bin: apps/act/%.act $(ACTION_BIN)
	@mkdir -p $(BUILD_DIR)
	@$(PBUILD) "$<" -o "$@" 
# Also the recipe of 'build' above (BUILD_DIR is build)
$(BUILD_DIR):
	@mkdir -p $@
	@$(DOT_CLEAN_CMD)

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------





# ------------------------------------------------------------------------------
# Toolchain Targets
# ------------------------------------------------------------------------------
.PHONY: tools pasm-lint pasm-lsp psim pasm action action-lsp vscode-ext vscode-install vscode-remove-old-pasm lint-tool dot-clean

tools: pasm-lint pasm-lsp pasm psim action action-lsp
	@$(DOT_CLEAN_CMD)

lint-tool: pasm-lint
pasm-lint: $(PASM_LINT_BIN)
	@$(DOT_CLEAN_CMD)

$(PASM_LINT_BIN): $(shell find apps/tools/pasm_lint -name "*.dart" 2>/dev/null) | $(TOOL_BIN_DIR)
	@echo "==> Compiling pasm_lint..."
	@cd apps/tools/pasm_lint && $(DART) pub get > /dev/null
	@$(DART) compile exe apps/tools/pasm_lint/bin/main.dart -o $@

pasm-lsp: $(PASM_LSP_BIN)
	@$(DOT_CLEAN_CMD)

$(PASM_LSP_BIN): $(shell find apps/tools/pasm_lsp -name "*.dart" 2>/dev/null) $(shell find apps/tools/pasm -name "*.dart" 2>/dev/null) $(shell find apps/tools/pasm_lint -name "*.dart" 2>/dev/null) | $(TOOL_BIN_DIR)
	@echo "==> Compiling pasm_lsp..."
	@cd apps/tools/pasm_lsp && $(DART) pub get > /dev/null
	@$(DART) compile exe apps/tools/pasm_lsp/bin/main.dart -o $@

pasm: $(PASM_BIN)
	@$(DOT_CLEAN_CMD)

$(PASM_BIN): $(shell find apps/tools/pasm -name "*.dart" 2>/dev/null) | $(TOOL_BIN_DIR)
	@echo "==> Compiling pasm..."
	@cd apps/tools/pasm && $(DART) pub get > /dev/null
	@$(DART) compile exe apps/tools/pasm/bin/main.dart -o $@

action: $(ACTION_BIN)
	@$(DOT_CLEAN_CMD)

$(ACTION_BIN): $(shell find apps/tools/action -name "*.dart" 2>/dev/null) apps/tools/action/pubspec.yaml | $(TOOL_BIN_DIR)
	@echo "==> Compiling action..."
	@cd apps/tools/action && $(DART) pub get > /dev/null
	@$(DART) compile exe apps/tools/action/bin/main.dart -o $@

action-lsp: $(ACTION_LSP_BIN)
	@$(DOT_CLEAN_CMD)

$(ACTION_LSP_BIN): $(shell find apps/tools/action_lsp apps/tools/action -name "*.dart" 2>/dev/null) apps/tools/action_lsp/pubspec.yaml | $(TOOL_BIN_DIR)
	@echo "==> Compiling action_lsp..."
	@cd apps/tools/action_lsp && $(DART) pub get > /dev/null
	@$(DART) compile exe apps/tools/action_lsp/bin/action_lsp.dart -o $@

# VS Code extensions: Action (the language, for any target) and Particle
# (Particle assembly). Need Node.js 20 or later and npm; not part of
# 'make tools'.
vscode-ext:
	@command -v npm > /dev/null || { echo "[FAIL] npm not found: install Node.js 20 or later (it includes npm)"; exit 1; }
	@mkdir -p $(BUILD_DIR)
	@for e in $(VSCODE_EXTS); do \
		echo "==> Packaging the $$e VS Code extension..."; \
		( cd $(VSCODE_DIR)/$$e && npm install --no-audit --no-fund && npm run compile && \
		  npx vsce package --skip-license --allow-missing-repository -o $(CURDIR)/$(BUILD_DIR)/$$e.vsix ) || exit 1; \
	done
	@$(DOT_CLEAN_CMD)

# Builds the servers the extensions start, packages the extensions and
# installs them in VS Code (replacing older versions).
vscode-install: $(ACTION_LSP_BIN) $(PASM_LSP_BIN) vscode-ext
	@if [ -z "$(VSCODE_CLI)" ]; then \
		echo "[FAIL] The VS Code command line ('code') was not found."; \
		echo "       In VS Code run 'Shell Command: Install 'code' command in PATH' from the command palette,"; \
		echo "       or install $(BUILD_DIR)/action.vsix and $(BUILD_DIR)/particle.vsix with 'Install from VSIX...' in the Extensions view."; \
		exit 1; \
	fi
	@for e in $(VSCODE_EXTS); do \
		echo "==> Installing $(BUILD_DIR)/$$e.vsix..."; \
		"$(VSCODE_CLI)" --install-extension $(BUILD_DIR)/$$e.vsix --force || exit 1; \
	done
	@if [ -d "$(HOME)/.vscode/extensions/particle-pasm" ]; then \
		echo "[NOTE] The old pasm extension is still installed ($(HOME)/.vscode/extensions/particle-pasm)."; \
		echo "       It also handles particle-asm files; remove it with 'make vscode-remove-old-pasm'."; \
	fi
	@echo "==> Done. Reload open VS Code windows (command palette: 'Developer: Reload Window')."
	@$(DOT_CLEAN_CMD)

# Removes the old, hand-installed pasm extension, which the Particle
# extension replaces.
vscode-remove-old-pasm:
	@if [ -d "$(HOME)/.vscode/extensions/particle-pasm" ]; then \
		rm -rf "$(HOME)/.vscode/extensions/particle-pasm" && echo "==> Removed $(HOME)/.vscode/extensions/particle-pasm. Reload open VS Code windows."; \
	else \
		echo "==> The old pasm extension is not installed; nothing to do."; \
	fi

$(TOOL_BIN_DIR):
	@mkdir -p $@

# Removes macOS ._ metadata files from the project (when dot_clean exists).
dot-clean:
	@$(DOT_CLEAN_CMD)

clean:
	@echo "==> Cleaning build artifacts and generated SV files..."
	@rm -rf $(BUILD_DIR)
	@rm -rf $(ROHD_DIR)/.dart_tool $(ROHD_DIR)/particle_top.sv $(ROHD_DIR)/*.synth.json $(ROHD_DIR)/*.bit
	@rm -rf $(PARCORE_DIR)/.dart_tool $(PARCORE_DIR)/parcore_top.sv $(PARCORE_DIR)/*.synth.json $(PARCORE_DIR)/*.bit
	@$(DOT_CLEAN_CMD)

psim: $(BUILD_DIR)/tools/psim
	@$(DOT_CLEAN_CMD)

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
