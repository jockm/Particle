# ==============================================================================
# Makefile - Particle & Parcore Master Build and Test Automation
# ==============================================================================

SHELL        := /bin/bash
DART         ?= dart
PYTHON       ?= python3

PBUILD       := ./pbuild
PSIM         := $(PYTHON) tools/psim.py

ROHD_DIR     := hdl/rohd
PARCORE_DIR  := hdl/parcore
BUILD_DIR    := build
PARCORE_BLD  := $(BUILD_DIR)/parcore

# Recursive wildcard across firmware/parcore
FIRMWARE_SRCS := $(shell find firmware/parcore -name '*.asm' 2>/dev/null)
FIRMWARE_BINS := $(patsubst firmware/parcore/%.asm,$(PARCORE_BLD)/%.bin,$(FIRMWARE_SRCS))

APP_ASM_SRCS  := $(wildcard apps/asm/*.asm)
APP_ASM_BINS  := $(patsubst apps/asm/%.asm,$(BUILD_DIR)/%.bin,$(APP_ASM_SRCS))

APP_ACT_SRCS  := $(wildcard apps/act16/*.act)
APP_ACT_BINS  := $(patsubst apps/act16/%.act,$(BUILD_DIR)/%.bin,$(APP_ACT_SRCS))

.PHONY: all setup test test-all test-particle test-parcore test-sim \
        lint lint-asm build generate generate-particle generate-parcore \
        firmware apps clean help

# ------------------------------------------------------------------------------
# Top-Level Targets
# ------------------------------------------------------------------------------

all: build test

help:
	@echo "Particle & Parcore Build Automation"
	@echo "==================================="
	@echo "  make setup            - Fetch Dart dependencies for rohd and parcore"
	@echo "  make lint-asm         - Statically lint all assembly files"
	@echo "  make build            - Build firmware, apps, and generate all HDL"
	@echo "  make test             - Run all unit and integration tests (ROHD + Sim)"
	@echo "  make test-particle    - Run Particle single-core ROHD tests"
	@echo "  make test-parcore     - Run Parcore multi-core ROHD tests"
	@echo "  make test-sim         - Run instruction simulator verification"
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
	@echo "==> Running Parcore multi-core ROHD tests..."
	@cd $(PARCORE_DIR) && $(DART) test

test-sim: apps
	@echo "==> Running instruction-level simulation tests (psim.py)..."
	@if [ -f "$(BUILD_DIR)/branch_suite.bin" ]; then \
		$(PSIM) $(BUILD_DIR)/branch_suite.bin; \
	fi

# ------------------------------------------------------------------------------
# Firmware & Application Targets (via pbuild)
# ------------------------------------------------------------------------------

build: firmware apps generate

firmware: $(FIRMWARE_BINS)

$(PARCORE_BLD)/%.bin: firmware/parcore/%.asm
	@mkdir -p $(dir $@)
	@$(PBUILD) "$<" -o "$@"

apps: $(APP_ASM_BINS) $(APP_ACT_BINS)

$(BUILD_DIR)/%.bin: apps/asm/%.asm | $(BUILD_DIR)
	@$(PBUILD) "$<" -o "$@"

$(BUILD_DIR)/%.bin: apps/act16/%.act | $(BUILD_DIR)
	@$(PBUILD) "$<" -o "$@"

$(BUILD_DIR):
	@mkdir -p $@

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------

clean:
	@echo "==> Cleaning build artifacts and generated SV files..."
	@rm -rf $(BUILD_DIR)
	@rm -rf $(ROHD_DIR)/.dart_tool $(ROHD_DIR)/particle_top.sv $(ROHD_DIR)/*.synth.json $(ROHD_DIR)/*.bit
	@rm -rf $(PARCORE_DIR)/.dart_tool $(PARCORE_DIR)/parcore_top.sv $(PARCORE_DIR)/*.synth.json $(PARCORE_DIR)/*.bit
