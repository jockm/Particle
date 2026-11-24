# ==============================================================================
# Makefile - Particle & Parcore Master Build and Test Automation
# ==============================================================================

SHELL        := /bin/bash
DART         ?= dart
PYTHON       ?= $(shell command -v python3 2>/dev/null || echo python)

ifeq ($(OS),Windows_NT)
EXEEXT       := .exe
else
EXEEXT       :=
endif

PBUILD       := ./pbuild
LLBUILD      := ./llbuild

# ------------------------------------------------------------------------------
# Simulator Selection
# ------------------------------------------------------------------------------
# Compiled Dart simulator (build it with 'make psim')
PSIM         := build/tools/psim$(EXEEXT)

ROHD_DIR     := hdl/particle
PARCORE_DIR  := hdl/parcore
BUILD_DIR    := build
TOOL_DIR     := apps/tools
TOOL_BIN_DIR := $(BUILD_DIR)/tools
PASM_LINT_BIN:= $(TOOL_BIN_DIR)/pasm_lint$(EXEEXT)
PASM_LSP_BIN := $(TOOL_BIN_DIR)/pasm_lsp$(EXEEXT)
PASM_BIN     := $(TOOL_BIN_DIR)/pasm$(EXEEXT)
ACTION_BIN   := $(TOOL_BIN_DIR)/action$(EXEEXT)
ACTION_LLVM_BIN := $(TOOL_BIN_DIR)/action_llvm$(EXEEXT)
LLVM_BUILD_DIR := $(BUILD_DIR)/llvm
ACTION_LSP_BIN := $(TOOL_BIN_DIR)/action_lsp$(EXEEXT)
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

# Parcore pipeline and ISA tests: 1 runs them in Verilator (fast), 0 in the
# ROHD simulator (Dart only). VERILATOR is the Verilator command.
PARCORE_FAST_SIM ?= 1
VERILATOR        ?= verilator
export VERILATOR

# Recursive wildcard across firmware/parcore
# (._* files are macOS metadata on drives without extended attributes)
FIRMWARE_SRCS := $(shell find firmware/parcore -name '*.asm' ! -name '._*' 2>/dev/null)
FIRMWARE_BINS := $(patsubst firmware/parcore/%.asm,$(PARCORE_BLD)/%.bin,$(FIRMWARE_SRCS))

APP_ASM_SRCS  := $(filter-out apps/asm/._%,$(wildcard apps/asm/*.asm))
APP_ASM_BINS  := $(patsubst apps/asm/%.asm,$(BUILD_DIR)/%.bin,$(APP_ASM_SRCS))

# Files with the line "//act:build llvm" are for the LLVM compiler only
APP_ACT_SRCS  := $(filter-out apps/act/._%,$(shell grep -L '^//act:build llvm$$' apps/act/*.act))
APP_ACT_BINS  := $(patsubst apps/act/%.act,$(BUILD_DIR)/%.bin,$(APP_ACT_SRCS))

# Multi-file programs: each folder in apps/act/multi is one program. Every
# .act and .asm file in it is built together into build/<folder>.bin, and a
# folder whose name starts with test_ is also run by compiler-tests.
MULTI_ROOT    := apps/act/multi
MULTI_NAMES   := $(filter-out ._%,$(notdir $(patsubst %/,%,$(wildcard $(MULTI_ROOT)/*/))))
MULTI_BINS    := $(patsubst %,$(BUILD_DIR)/%.bin,$(MULTI_NAMES))
MULTI_TESTS   := $(filter test_%,$(MULTI_NAMES))

.PHONY: all setup test test-all test-particle test-particle-isa test-parcore test-parcore-isa test-sim test-sim-cluster compiler-tests test-lint \
        lint lint-asm build generate generate-particle generate-parcore \
        generate-ulx3s ulx3s-bit ulx3s-timing ulx3s-prog ulx3s-flash ulx3s-term firmware apps clean help \
        parcore-guest parcore-image generate-parcore-ulx3s parcore-bit parcore-timing parcore-prog parcore-flash parcore-profile

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
	@echo "  make test-particle    - Run Particle single-core ROHD tests (includes the differential ISA test)"
	@echo "  make test-particle-isa - Compare the core with psim: test/isa programs and random programs (ISA_RANDOM_SEEDS=...)"
	@echo "  make test-parcore     - Run Parcore multi-core tests (Verilator; PARCORE_FAST_SIM=0 for the ROHD simulator)"
	@echo "  make test-parcore-isa - Build and run official RISC-V ISA tests (rv32ui, rv32um, rv32uzbb)"
	@echo "  make test-sim         - Run instruction simulator verification"
	@echo "  make test-sim-cluster - Run the simulator's multi-core (cluster) tests"
	@echo "  make compiler-tests   - Run Action compiler unit tests and all test suites in psim"
	@echo "  make action           - Build the Action compiler ($(ACTION_BIN))"
	@echo "  make action-lsp       - Build the Action language server ($(ACTION_LSP_BIN))"
	@echo "  make llvm-tools       - Build the Action compiler for LLVM ($(ACTION_LLVM_BIN))"
	@echo "  make llvm-tests       - Build the Action test suites with LLVM and run them on this computer"
	@echo "  make deps             - Fetch the modules action.json requires (action --fetch; needs git)"
	@echo "  make vendor           - Copy the modules the build uses into vendor/ (action --vendor)"
	@echo "  make deps-tests       - Test fetching, vendoring and building with modules (needs git)"
	@echo "  make vscode-ext       - Package the VS Code extensions (build/action.vsix, build/particle.vsix; needs npm)"
	@echo "  make vscode-install   - Build the language servers and extensions, and install the extensions in VS Code"
	@echo "  make vscode-remove-old-pasm - Remove the old hand-installed pasm extension"
	@echo "  make generate         - Generate synthesizable SystemVerilog (.sv)"
	@echo "  make generate-ulx3s   - Generate the ULX3S design with a program (ULX3S_PROGRAM=...) in build/ulx3s"
	@echo "  make ulx3s-bit        - Synthesize, place and route the ULX3S design (build/ulx3s/particle_ulx3s.bit)"
	@echo "  make ulx3s-timing     - Show the last ULX3S build's Fmax and critical path (from nextpnr.log)"
	@echo "  make ulx3s-prog       - Load build/ulx3s/particle_ulx3s.bit into the ULX3S (openFPGALoader)"
	@echo "  make ulx3s-flash      - Write build/ulx3s/particle_ulx3s.bit to the ULX3S flash (kept across power cycles)"
	@echo "  make ulx3s-term       - Open the ULX3S FTDI UART (ULX3S_PORT=..., ULX3S_BAUD=1000000); Ctrl-] leaves"
	@echo "  make parcore-guest    - Build the RISC-V guest program (PARCORE_GUEST=apps/riscv/hello.S; RISC-V GCC or LLVM)"
	@echo "  make parcore-image    - Build the Parcore boot image (stage firmware + guest) in build/parcore_ulx3s"
	@echo "  make parcore-bit      - Synthesize, place and route Parcore for the ULX3S (PARCORE_CLOCK_HZ=...)"
	@echo "  make parcore-timing   - Show the last Parcore build's Fmax and critical path"
	@echo "  make parcore-prog     - Load build/parcore_ulx3s/parcore_ulx3s.bit into the ULX3S"
	@echo "  make parcore-flash    - Write build/parcore_ulx3s/parcore_ulx3s.bit to the ULX3S flash"
	@echo "  make parcore-profile  - Profile Parcore running PARCORE_PROFILE_GUEST (apps/riscv/bench.S) in Verilator"
	@echo "  make firmware         - Assemble all Parcore pipeline microkernels"
	@echo "  make apps             - Build Action and ASM application binaries (and each apps/act/multi folder)"
	@echo "  make clean            - Remove all build artifacts and generated SV"
	@echo "  make dot-clean        - Remove macOS ._ metadata files (where dot_clean exists)"
	@echo "  make install-hooks    - Install the project's git hooks (apps/tools/git-hooks) into this clone"

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
# ULX3S board (ECP5 85F): one Particle core, 64 KiB block RAM, two UARTs
# ------------------------------------------------------------------------------
# ULX3S_PROGRAM is built with pbuild into a hex image and loaded into the block
# RAM; the bitstream has to be rebuilt to change it.
ULX3S_BLD      := $(BUILD_DIR)/ulx3s
ULX3S_PROGRAM  ?= apps/asm/ulx3s_echo.asm
ULX3S_CLOCK_HZ ?= 35000000
ULX3S_LPF      := $(ROHD_DIR)/boards/ulx3s/ulx3s_v20.lpf
YOSYS          ?= yosys
NEXTPNR_ECP5   ?= nextpnr-ecp5
ECPPACK        ?= ecppack
OPENFPGALOADER ?= openFPGALoader

generate-ulx3s: setup $(PASM_BIN) $(PASM_LINT_BIN)
	@echo "==> Building $(ULX3S_PROGRAM) for the ULX3S block RAM..."
	@mkdir -p $(ULX3S_BLD)
	@$(PBUILD) "$(ULX3S_PROGRAM)" -o "$(ULX3S_BLD)/program.hex" --format hex
	@echo "==> Generating the ULX3S design (build/ulx3s/particle_ulx3s.sv)..."
	@cd $(ROHD_DIR) && $(DART) run bin/generate_ulx3s.dart --hex ../../$(ULX3S_BLD)/program.hex \
		--out ../../$(ULX3S_BLD) --clock-hz $(ULX3S_CLOCK_HZ)
	@$(DOT_CLEAN_CMD)

ulx3s-bit: generate-ulx3s
	@echo "==> Synthesizing (Yosys; log in build/ulx3s/yosys.log)..."
	@cd $(ULX3S_BLD) && $(YOSYS) -q -l yosys.log \
		-p "read_verilog -sv particle_ulx3s.sv; synth_ecp5 -top ulx3s_board -json particle_ulx3s.json"
	@echo "==> Placing and routing for the 85F (nextpnr; log in build/ulx3s/nextpnr.log)..."
	@cd $(ULX3S_BLD) && $(NEXTPNR_ECP5) -q --85k --package CABGA381 --lpf ../../$(ULX3S_LPF) \
		--json particle_ulx3s.json --textcfg particle_ulx3s.config \
		--freq $$(( $(ULX3S_CLOCK_HZ) / 1000000 )) -l nextpnr.log
	@cd $(ULX3S_BLD) && $(ECPPACK) --compress particle_ulx3s.config particle_ulx3s.bit
	@grep "Max frequency for clock" $(ULX3S_BLD)/nextpnr.log | tail -1
	@echo "==> Bitstream: $(ULX3S_BLD)/particle_ulx3s.bit"
	@$(DOT_CLEAN_CMD)

# The critical path from the last ulx3s-bit: one line per step (type, delay,
# running total, where), long cell names cut short
ulx3s-timing:
	@if [ ! -f "$(ULX3S_BLD)/nextpnr.log" ]; then \
		echo "[FAIL] $(ULX3S_BLD)/nextpnr.log not found: run make ulx3s-bit first."; exit 1; \
	fi
	@grep "Max frequency for clock" $(ULX3S_BLD)/nextpnr.log | tail -1
	@sed -n '/Critical path report for clock/,/^Info: *$$/p' $(ULX3S_BLD)/nextpnr.log | \
		awk '$$2=="clk-to-q" || $$2=="logic" || $$2=="routing" || $$2=="setup" { \
			n = $$6; if (length(n) > 90) n = substr(n, 1, 90) "..."; \
			printf "%-9s %6s %7s  %s\n", $$2, $$3, $$4, n }'

ulx3s-prog:
	@if [ ! -f "$(ULX3S_BLD)/particle_ulx3s.bit" ]; then \
		echo "[FAIL] $(ULX3S_BLD)/particle_ulx3s.bit not found: run make ulx3s-bit first."; exit 1; \
	fi
	$(OPENFPGALOADER) -b ulx3s "$(ULX3S_BLD)/particle_ulx3s.bit"

# The same, written to the configuration flash: the board loads it at every
# power-up (until something else is written there)
ulx3s-flash:
	@if [ ! -f "$(ULX3S_BLD)/particle_ulx3s.bit" ]; then \
		echo "[FAIL] $(ULX3S_BLD)/particle_ulx3s.bit not found: run make ulx3s-bit first."; exit 1; \
	fi
	$(OPENFPGALOADER) -b ulx3s -f "$(ULX3S_BLD)/particle_ulx3s.bit"

# The FTDI UART: the first USB serial port found, unless ULX3S_PORT is given.
# On macOS that is the call-out device (/dev/cu.*), which opens at once; the
# /dev/tty.* one waits for a carrier signal the board doesn't send. The
# terminal is a small Python script (screen can't set 1 Mbps on macOS).
# Ctrl-] leaves.
ULX3S_PORT ?= $(firstword $(wildcard /dev/cu.usbserial-* /dev/ttyUSB*))
ULX3S_BAUD ?= 1000000

ulx3s-term:
	@if [ -z "$(ULX3S_PORT)" ]; then \
		echo "[FAIL] No USB serial port found: connect the ULX3S, or give ULX3S_PORT=/dev/..."; exit 1; \
	fi
	@$(PYTHON) $(ROHD_DIR)/boards/ulx3s/ulx3s_term.py $(ULX3S_PORT) $(ULX3S_BAUD)

# ------------------------------------------------------------------------------
# Parcore on the ULX3S: the conductor loads the stage firmware and a RISC-V
# guest program (PARCORE_GUEST, built with a RISC-V GCC or LLVM toolchain) from the
# image ROM built into the bitstream, then releases the cores. The guest uses
# the FTDI UART (make ulx3s-term), the LEDs and the buttons; FIRE1 restarts.
# ------------------------------------------------------------------------------
PARCORE_ULX3S_BLD  := $(BUILD_DIR)/parcore_ulx3s
PARCORE_GUEST      ?= apps/riscv/hello.S
PARCORE_GUEST_BIN  := $(BUILD_DIR)/riscv/$(basename $(notdir $(PARCORE_GUEST))).bin
PARCORE_CLOCK_HZ   ?= 25000000

parcore-guest:
	@bash apps/riscv/build_riscv_guest.sh "$(PARCORE_GUEST)" "$(PARCORE_GUEST_BIN)"

parcore-image: setup firmware parcore-guest
	@mkdir -p $(PARCORE_ULX3S_BLD)
	@cd $(PARCORE_DIR) && $(DART) run bin/build_parcore_image.dart \
		--core0 ../../$(PARCORE_BLD)/riscv/core0_if.bin --core1 ../../$(PARCORE_BLD)/riscv/core1_id.bin \
		--core2 ../../$(PARCORE_BLD)/riscv/core2_ex.bin --core3 ../../$(PARCORE_BLD)/riscv/core3_mem.bin \
		--guest ../../$(PARCORE_GUEST_BIN) --out ../../$(PARCORE_ULX3S_BLD)/parcore_image.bin

generate-parcore-ulx3s: parcore-image
	@echo "==> Generating the Parcore ULX3S design (build/parcore_ulx3s/parcore_ulx3s.sv)..."
	@cd $(PARCORE_DIR) && $(DART) run bin/generate_parcore_ulx3s.dart \
		--conductor ../../$(PARCORE_BLD)/conductor/conductor.bin \
		--image ../../$(PARCORE_ULX3S_BLD)/parcore_image.bin \
		--out ../../$(PARCORE_ULX3S_BLD) --clock-hz $(PARCORE_CLOCK_HZ)
	@$(DOT_CLEAN_CMD)

parcore-bit: generate-parcore-ulx3s
	@echo "==> Synthesizing (Yosys; log in build/parcore_ulx3s/yosys.log)..."
	@cd $(PARCORE_ULX3S_BLD) && $(YOSYS) -q -l yosys.log \
		-p "read_verilog -sv parcore_ulx3s.sv; synth_ecp5 -top ulx3s_board -json parcore_ulx3s.json"
	@echo "==> Placing and routing for the 85F (nextpnr; log in build/parcore_ulx3s/nextpnr.log)..."
	@cd $(PARCORE_ULX3S_BLD) && $(NEXTPNR_ECP5) -q --85k --package CABGA381 --lpf ../../$(ULX3S_LPF) \
		--json parcore_ulx3s.json --textcfg parcore_ulx3s.config --router router2 \
		--freq $$(( $(PARCORE_CLOCK_HZ) / 1000000 )) -l nextpnr.log
	@cd $(PARCORE_ULX3S_BLD) && $(ECPPACK) --compress parcore_ulx3s.config parcore_ulx3s.bit
	@grep "Max frequency for clock" $(PARCORE_ULX3S_BLD)/nextpnr.log | tail -1
	@echo "==> Bitstream: $(PARCORE_ULX3S_BLD)/parcore_ulx3s.bit"
	@$(DOT_CLEAN_CMD)

# The critical path from the last parcore-bit
parcore-timing:
	@if [ ! -f "$(PARCORE_ULX3S_BLD)/nextpnr.log" ]; then \
		echo "[FAIL] $(PARCORE_ULX3S_BLD)/nextpnr.log not found: run make parcore-bit first."; exit 1; \
	fi
	@grep "Max frequency for clock" $(PARCORE_ULX3S_BLD)/nextpnr.log | tail -1
	@sed -n '/Critical path report for clock/,/^Info: *$$/p' $(PARCORE_ULX3S_BLD)/nextpnr.log | \
		awk '$$2=="clk-to-q" || $$2=="logic" || $$2=="routing" || $$2=="setup" { \
			n = $$6; if (length(n) > 90) n = substr(n, 1, 90) "..."; \
			printf "%-9s %6s %7s  %s\n", $$2, $$3, $$4, n }'

parcore-prog:
	@if [ ! -f "$(PARCORE_ULX3S_BLD)/parcore_ulx3s.bit" ]; then \
		echo "[FAIL] $(PARCORE_ULX3S_BLD)/parcore_ulx3s.bit not found: run make parcore-bit first."; exit 1; \
	fi
	$(OPENFPGALOADER) -b ulx3s "$(PARCORE_ULX3S_BLD)/parcore_ulx3s.bit"

# Profile Parcore running a guest in Verilator: cycles per RISC-V instruction
# (overall and per phase) and where each stage core's cycles go
PARCORE_PROFILE_GUEST ?= apps/riscv/bench.S
PARCORE_PROFILE_BIN   := $(BUILD_DIR)/riscv/$(basename $(notdir $(PARCORE_PROFILE_GUEST))).bin

parcore-profile: setup firmware
	@bash apps/riscv/build_riscv_guest.sh "$(PARCORE_PROFILE_GUEST)" "$(PARCORE_PROFILE_BIN)"
	@cd $(PARCORE_DIR) && $(DART) run bin/profile_parcore.dart --guest ../../$(PARCORE_PROFILE_BIN)
	@$(DOT_CLEAN_CMD)

parcore-flash:
	@if [ ! -f "$(PARCORE_ULX3S_BLD)/parcore_ulx3s.bit" ]; then \
		echo "[FAIL] $(PARCORE_ULX3S_BLD)/parcore_ulx3s.bit not found: run make parcore-bit first."; exit 1; \
	fi
	$(OPENFPGALOADER) -b ulx3s -f "$(PARCORE_ULX3S_BLD)/parcore_ulx3s.bit"

# ------------------------------------------------------------------------------
# Verification & Test Suites
# ------------------------------------------------------------------------------

test: test-particle test-parcore test-sim test-sim-cluster
	@$(DOT_CLEAN_CMD)

# The tests assemble programs with pasm, compare the core with psim, and run
# firmware and app binaries
PARTICLE_TEST_DEPS := setup $(PASM_BIN) $(PSIM) $(BUILD_DIR)/ulx3s_echo.bin \
	$(BUILD_DIR)/c0_stimulus.bin $(PARCORE_BLD)/riscv/core1_dispatch.bin

test-particle: $(PARTICLE_TEST_DEPS)
	@echo "==> Running Particle single-core ROHD tests..."
	@cd $(ROHD_DIR) && $(DART) test

# Differential ISA test only: test/isa/*.asm and seeded random programs, run in
# psim and on the ROHD core. ISA_RANDOM_SEEDS=1,2,3 picks the random seeds
# (default 1..8; empty for none).
test-particle-isa: $(PARTICLE_TEST_DEPS)
	@echo "==> Running the differential ISA test (psim vs ROHD core)..."
	@cd $(ROHD_DIR) && $(if $(filter undefined,$(origin ISA_RANDOM_SEEDS)),,ISA_RANDOM_SEEDS="$(ISA_RANDOM_SEEDS)") $(DART) test test/isa_diff_test.dart

test-parcore: setup firmware guest-tests
	@echo "==> Running Parcore unit tests..."
	@(cd $(PARCORE_DIR) && $(DART) test test/parcore_top_test.dart test/parcore_pipeline_trace_test.dart \
		test/spi_flash_rom_test.dart test/conductor_boot_test.dart)
	@echo "==> Booting the whole Parcore ULX3S design from its image ROM (Verilator)..."
	@(cd $(PARCORE_DIR) && PARCORE_FAST_SIM=$(PARCORE_FAST_SIM) $(DART) test test/parcore_ulx3s_boot_test.dart)
	@echo "==> Running Parcore RV32IM pipeline regression suite..."
	@(cd $(PARCORE_DIR) && PARCORE_FAST_SIM=$(PARCORE_FAST_SIM) bash ./test_pipeline.sh)

test-parcore-isa: setup firmware
	@if [ ! -d "third_party/riscv-tests/isa" ]; then \
		echo "[FAIL] third_party/riscv-tests/isa not found."; \
		echo "       Initialize the submodule first: git submodule update --init third_party/riscv-tests"; \
		exit 1; \
	fi
	@echo "==> Building official RISC-V ISA test binaries (rv32ui, rv32um, rv32uzbb)..."
	@bash $(PARCORE_DIR)/test/riscv_tests/build_riscv_tests.sh
	@echo "==> Running official RISC-V ISA tests on Parcore..."
	@(cd $(PARCORE_DIR) && PARCORE_FAST_SIM=$(PARCORE_FAST_SIM) $(DART) test -j 1 -r compact test/parcore_riscv_isa_test.dart)
	@$(DOT_CLEAN_CMD)

# Run instruction-level simulation tests with $(PSIM).
test-sim: $(PSIM) $(BUILD_DIR)/branch_suite.bin
	@echo "==> Running instruction-level simulation tests ($(PSIM))..."
	$(PSIM) $(BUILD_DIR)/branch_suite.bin
	@$(DOT_CLEAN_CMD)

# Multi-core simulator tests: each cluster file in apps/asm/cluster runs its
# programs (assembled into build/cluster) and must end with the exit code
# listed here: 0 when every core ends with TRAP 0, 19 for a deadlock.
CLUSTER_TESTS := stream:0 mbox:0 shared:0 deadlock:19

test-sim-cluster: $(PSIM) $(PASM_BIN)
	@echo "==> Running multi-core simulator tests..."
	@mkdir -p $(BUILD_DIR)/cluster
	@for f in apps/asm/cluster/*.asm; do \
		$(PASM_BIN) "$$f" -I . -o $(BUILD_DIR)/cluster/$$(basename "$${f%.asm}").bin > /dev/null || exit 1; \
	done
	@failed=0; \
	for t in $(CLUSTER_TESTS); do \
		name=$${t%%:*}; want=$${t##*:}; \
		$(PSIM) -C apps/asm/cluster/$$name.json --max-cycles 1000000 > $(BUILD_DIR)/cluster/$$name.out; got=$$?; \
		if [ $$got -eq $$want ]; then echo "  [PASS] $$name (exit $$got)"; \
		else echo "  [FAIL] $$name: exit $$got, expected $$want"; tail -5 $(BUILD_DIR)/cluster/$$name.out; failed=1; fi; \
	done; \
	if [ $$failed -ne 0 ]; then exit 1; fi
	@echo "==> [PASS] All multi-core simulator tests passed."

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
ACT_TEST_SRCS := $(filter-out $(ACT_TRAP_TESTS) apps/act/._%,$(wildcard apps/act/test_*.act))
# A test with the line "//act:build llvm" uses what only the LLVM compiler
# has (such as f32 and f64), and is skipped here. The test programs use only
# the plain forms "//act:build llvm" and "//act:build particle".
PARTICLE_SKIP_MARKER := ^//act:build llvm$$

compiler-tests: $(ACTION_BIN) $(PASM_BIN) $(PASM_LINT_BIN) $(PSIM)
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
		if grep -q '$(PARTICLE_SKIP_MARKER)' "$$src"; then echo "Skipping (LLVM only): $$src"; continue; fi; \
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
		for name in $(MULTI_TESTS); do \
			dir="$(MULTI_ROOT)/$$name"; \
			bin="$(BUILD_DIR)/$$name.bin"; \
			srcs=$$(ls "$$dir"/*.act "$$dir"/*.asm 2>/dev/null); \
			echo "----------------------------------------------------------------"; \
			echo "Testing multi-file program: $$dir -> $$bin"; \
			echo "  files: "$$srcs; \
			$(PBUILD) $$srcs -o "$$bin" || { echo "[FAIL] Build failed for $$dir"; failed=1; break; }; \
			$(PSIM) "$$bin" || { code=$$?; echo "[FAIL] $$bin failed simulation"; sim_result $$code; failed=1; break; }; \
		done; \
	fi; \
	if [ $$failed -ne 0 ]; then \
		echo "==> [FAIL] Action compiler tests failed."; \
		exit 1; \
	else \
		echo "==> [PASS] All Action compiler tests passed successfully."; \
	fi
	@$(DOT_CLEAN_CMD)

# ------------------------------------------------------------------------------
# Action through LLVM (action_llvm and llbuild)
# ------------------------------------------------------------------------------
# The same test programs, built for this computer with llbuild and run
# natively: a test passes with exit status 0 (trap(0)); trap(15) and failed
# run-time checks exit with 15. A test that needs Particle hardware (fixed
# addresses, FIFOs, trap handlers, inline assembly) has the line
# "//act:build particle" and is skipped; so is a multi-file program with such
# a file or an .asm file. Outputs go to build/llvm.
LLVM_MARKER := ^//act:build particle$$

# Modules (see action.json "requires"): fetching needs git
deps: $(ACTION_BIN)
	@$(ACTION_BIN) --fetch

vendor: $(ACTION_BIN)
	@$(ACTION_BIN) --vendor

deps-tests: $(ACTION_BIN) $(ACTION_LLVM_BIN) $(PASM_BIN) $(PASM_LINT_BIN) $(PSIM)
	@echo "==> Running module tests (fetch, vendor, build on both targets)..."
	@sh apps/tools/action/test/deps_e2e.sh .

llvm-tests: $(ACTION_LLVM_BIN)
	@mkdir -p $(LLVM_BUILD_DIR)
	@echo "==> Building and running Action test suites with LLVM ($${CLANG:-clang})..."
	@passed=0; skipped=0; failed=0; \
	for src in $(ACT_TEST_SRCS); do \
		base=$$(basename "$$src" .act); \
		if grep -q '$(LLVM_MARKER)' "$$src"; then skipped=$$((skipped + 1)); continue; fi; \
		echo "Testing: $$src -> $(LLVM_BUILD_DIR)/$$base$(EXEEXT)"; \
		$(LLBUILD) "$$src" -o "$(LLVM_BUILD_DIR)/$$base$(EXEEXT)" || { echo "[FAIL] Build failed for $$src"; failed=1; break; }; \
		"$(LLVM_BUILD_DIR)/$$base$(EXEEXT)" || { echo "[FAIL] $$base exited with $$?"; failed=1; break; }; \
		passed=$$((passed + 1)); \
	done; \
	if [ $$failed -eq 0 ]; then \
		for src in $(ACT_TRAP_TESTS); do \
			base=$$(basename "$$src" .act); \
			if grep -q '$(LLVM_MARKER)' "$$src"; then skipped=$$((skipped + 1)); continue; fi; \
			marker=$$(sed -n 's|^// Must stop at: ||p' "$$src" | head -1); \
			case "$$marker" in *ull*) want="null reference" ;; *) want="is out of range" ;; esac; \
			echo "Testing (must stop with exit 15: $$want): $$src -> $(LLVM_BUILD_DIR)/$$base$(EXEEXT)"; \
			$(LLBUILD) "$$src" -o "$(LLVM_BUILD_DIR)/$$base$(EXEEXT)" || { echo "[FAIL] Build failed for $$src"; failed=1; break; }; \
			msg=$$("$(LLVM_BUILD_DIR)/$$base$(EXEEXT)" 2>&1 > /dev/null); code=$$?; echo "  $$msg"; \
			if [ $$code -ne 15 ] || ! echo "$$msg" | grep -q "^action: .*$$want"; then \
				echo "[FAIL] expected exit 15 with '$$want', got exit $$code"; failed=1; break; fi; \
			passed=$$((passed + 1)); \
		done; \
	fi; \
	if [ $$failed -eq 0 ]; then \
		for name in $(MULTI_TESTS); do \
			dir="$(MULTI_ROOT)/$$name"; \
			if ls "$$dir"/*.asm > /dev/null 2>&1 || grep -qs '$(LLVM_MARKER)' "$$dir"/*.act; then skipped=$$((skipped + 1)); continue; fi; \
			echo "Testing multi-file program: $$dir -> $(LLVM_BUILD_DIR)/$$name$(EXEEXT)"; \
			$(LLBUILD) "$$dir"/*.act -o "$(LLVM_BUILD_DIR)/$$name$(EXEEXT)" || { echo "[FAIL] Build failed for $$dir"; failed=1; break; }; \
			"$(LLVM_BUILD_DIR)/$$name$(EXEEXT)" || { echo "[FAIL] $$name exited with $$?"; failed=1; break; }; \
			passed=$$((passed + 1)); \
		done; \
	fi; \
	if [ $$failed -ne 0 ]; then echo "==> [FAIL] LLVM tests failed."; exit 1; fi; \
	echo "==> [PASS] $$passed LLVM tests passed ($$skipped Particle-only tests skipped)."
	@$(DOT_CLEAN_CMD)

# ------------------------------------------------------------------------------
# Linter Test Suite (pasm_lint)
# ------------------------------------------------------------------------------
LINT_FAIL_SRCS := $(filter-out %/._%,$(wildcard apps/asm/lint_failures/*.asm))
LINT_PASS_SRCS := $(filter-out %/._%,$(wildcard apps/asm/lint_passes/*.asm))

test-lint: pasm-lint
	@echo "==> Running pasm_lint test suite..."
	@echo "  -> Checking that the linter and the assembler agree..."
	@cd apps/tools/pasm_lint && $(DART) pub get > /dev/null && $(DART) test
	@echo "  -> Validating production assembly sources (must pass)..."
	@for f in apps/asm/*.asm $(LINT_PASS_SRCS); do \
		$(PASM_LINT_BIN) "$$f" -I lib > /dev/null || { echo "[FAIL] Unexpected lint failure on valid file: $$f"; exit 1; }; \
	done
	@echo "  -> Validating negative fixture constraints (must fail)..."
	@for f in $(LINT_FAIL_SRCS); do \
		if $(PASM_LINT_BIN) "$$f" -I lib > /dev/null 2>&1; then \
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

firmware: $(PASM_BIN) $(PASM_LINT_BIN) $(FIRMWARE_BINS)
	@$(DOT_CLEAN_CMD)

$(PARCORE_BLD)/%.bin: firmware/parcore/%.asm $(PASM_BIN)
	@mkdir -p $(dir $@)
	@$(PBUILD) "$<" -o "$@"

apps: $(PASM_BIN) $(PASM_LINT_BIN) $(ACTION_BIN) $(APP_ASM_BINS) $(APP_ACT_BINS) $(MULTI_BINS)
	@$(DOT_CLEAN_CMD)

$(BUILD_DIR)/branch_suite.bin: apps/asm/branch_suite.asm $(PASM_BIN) $(PASM_LINT_BIN)
	@mkdir -p $(BUILD_DIR)
	@$(PBUILD) "$<" -o "$@"

$(BUILD_DIR)/%.bin: apps/asm/%.asm $(PASM_BIN) $(PASM_LINT_BIN)
	@mkdir -p $(BUILD_DIR)
	@$(PBUILD) "$<" -o "$@"

$(BUILD_DIR)/%.bin: apps/act/%.act $(ACTION_BIN) $(PASM_BIN) $(PASM_LINT_BIN)
	@mkdir -p $(BUILD_DIR)
	@$(PBUILD) "$<" -o "$@"

# A multi-file program: everything in its folder, rebuilt when any file changes
.SECONDEXPANSION:
$(MULTI_BINS): $(BUILD_DIR)/%.bin: $$(filter-out %/._%,$$(wildcard $(MULTI_ROOT)/$$*/*.act $(MULTI_ROOT)/$$*/*.asm)) $(ACTION_BIN) $(PASM_BIN) $(PASM_LINT_BIN)
	@mkdir -p $(BUILD_DIR)
	@$(PBUILD) $(filter %.act %.asm,$^) -o "$@"

# Also the recipe of 'build' above (BUILD_DIR is build)
$(BUILD_DIR):
	@mkdir -p $@
	@$(DOT_CLEAN_CMD)

# ------------------------------------------------------------------------------
# Toolchain Targets
# ------------------------------------------------------------------------------
.PHONY: deps vendor deps-tests
.PHONY: tools pasm-lint pasm-lsp psim pasm action action-lsp llvm-tools llvm-tests vscode-ext vscode-install vscode-remove-old-pasm lint-tool dot-clean install-hooks

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

llvm-tools: $(ACTION_LLVM_BIN)
	@$(DOT_CLEAN_CMD)

$(ACTION_LLVM_BIN): $(shell find apps/tools/action -name "*.dart" 2>/dev/null) apps/tools/action/pubspec.yaml | $(TOOL_BIN_DIR)
	@echo "==> Compiling action_llvm..."
	@cd apps/tools/action && $(DART) pub get > /dev/null
	@$(DART) compile exe apps/tools/action/bin/action_llvm.dart -o $@

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
		if [ ! -f "$(VSCODE_DIR)/$$e/package.json" ]; then \
			echo "[FAIL] $(VSCODE_DIR)/$$e/package.json is missing: the extension's source is incomplete."; \
			exit 1; \
		fi; \
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

# Installs the git hooks in apps/tools/git-hooks into this clone's hooks
# directory. A different hook already there is kept as <name>.bak.
GIT_HOOKS_DIR := apps/tools/git-hooks
GIT_HOOKS     := pre-commit

install-hooks:
	# Not a hook, but a handy alias
	@git config --global alias.ac '!f() { msg="$1"; shift; git add "$@" && git commit -m "$msg"; }; f'
	
	# Now a hook that does a dot_clean before commit.
	@git rev-parse --git-dir > /dev/null 2>&1 || { echo "[FAIL] Not inside a git repository."; exit 1; }
	@hooks="$$(git rev-parse --git-path hooks)"; mkdir -p "$$hooks"; \
	for h in $(GIT_HOOKS); do \
		src="$(GIT_HOOKS_DIR)/$$h"; dst="$$hooks/$$h"; \
		if [ -f "$$dst" ] && ! cmp -s "$$src" "$$dst"; then \
			cp "$$dst" "$$dst.bak" && echo "==> Kept the existing $$h hook as $$dst.bak"; \
		fi; \
		cp "$$src" "$$dst" && chmod +x "$$dst" && echo "==> Installed the $$h hook ($$dst)"; \
	done

clean:
	@echo "==> Cleaning build artifacts and generated SV files..."
	@rm -rf $(BUILD_DIR)
	@rm -rf $(ROHD_DIR)/.dart_tool $(ROHD_DIR)/particle_top.sv $(ROHD_DIR)/*.synth.json $(ROHD_DIR)/*.bit
	@rm -rf $(PARCORE_DIR)/.dart_tool $(PARCORE_DIR)/parcore_top.sv $(PARCORE_DIR)/*.synth.json $(PARCORE_DIR)/*.bit
	@$(DOT_CLEAN_CMD)

psim: $(PSIM)
	@$(DOT_CLEAN_CMD)

$(PSIM): apps/tools/psim/bin/main.dart apps/tools/psim/lib/core.dart apps/tools/psim/lib/line_reader.dart | $(TOOL_BIN_DIR)
	@echo "==> Compiling psim..."
	@$(DART) compile exe apps/tools/psim/bin/main.dart -o $@

# --- Guest RV32 Test Program Targets ---
GUEST_GEN_DIR   := apps/asm/gen
GUEST_GEN_SRCS  := $(wildcard $(GUEST_GEN_DIR)/gen_guest_rv32*.py)
GUEST_TEST_BINS := $(BUILD_DIR)/guest_rv32_test.bin \
                   $(BUILD_DIR)/guest_rv32_branch.bin \
                   $(BUILD_DIR)/guest_rv32_mem_test.bin \
                   $(BUILD_DIR)/guest_rv32_mul_test.bin \
                   $(BUILD_DIR)/guest_rv32_signed_div.bin

$(GUEST_TEST_BINS): $(GUEST_GEN_SRCS)
	@mkdir -p $(BUILD_DIR)
	@for s in $(GUEST_GEN_SRCS); do $(PYTHON) "$$s"; done

guest-tests: $(GUEST_TEST_BINS)

.PHONY: guest-tests