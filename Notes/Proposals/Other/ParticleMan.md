# ParticleMan: Multi-Core Particle OS Proposal

**Status:** Proposal
**Target:** Particle CPUs on the Lattice ECP5 ULX3S
**Initial hardware:** ULX3S 3M USB UART serial console and SD-card interface

## 1. Summary

ParticleMan is a small supervisory operating system for a system with at least two Particle CPU cores. One core is reserved for the OS and owns the machine's shared I/O devices. The remaining cores run one user process each. This keeps the initial design simple: a core is either available or occupied by one process, and the OS core coordinates process loading, termination, console input/output, and storage access.

The initial system is intended for bring-up and simple applications, not as a general-purpose multitasking OS. It has no requirement for virtual memory, preemptive scheduling, or multiple processes per worker core.

## 2. System layout

```text
                  +-----------------------------------+
                  | Core 0: ParticleMan               |
                  | shell, loader, process supervisor |
                  +---------+-------------------------+
                            | OS requests / responses
               +------------+-------------+
               |                          |
        +------v------+            +------v------+
        | Worker core |    ...     | Worker core|
        | one process |            | one process|
        +-------------+            +-------------+
               |                          |
               +------- shared memory -----+
                            |
        +-------------------+-------------------+
        |                                       |
  3M USB UART                              SD-card interface
  serial console                            program/files
```

Physical core 0 runs ParticleMan from its own reserved memory. It exclusively owns the UART and SD-card controller in the first version. Every core's memory size is independently configurable. Worker cores run user programs and request OS services rather than accessing those devices directly. The number of worker cores is configuration-dependent; the design requires at least one.

Each worker core has a small process record maintained by ParticleMan:

| Field | Purpose |
|---|---|
| Core number | Identifies the worker and the core to start, stop, or report |
| State | `free`, `loading`, `running`, `waiting for OS`, or `stopping` |
| Program name | Filename used to load the process |
| Arguments | Command-line arguments supplied to the process |
| Exit status | Result reported when the process terminates |
| Pending request | OS service and request data, if any |

The worker's core number is also its initial process slot. A separate PID namespace can be added later if processes can migrate or share a core.

## 3. Boot and ownership

1. Hardware reset starts the ParticleMan image on the designated OS core and holds worker cores inactive.
2. ParticleMan initializes its memory, the UART console, the SD-card interface, and per-core request/response state.
3. ParticleMan makes worker cores available and starts the command shell on the serial console.
4. On `run`, ParticleMan selects a free worker, loads the program and startup arguments, initializes that core's execution state, then releases it to run.
5. On process exit or `kill`, ParticleMan records the result, cleans up the process slot, and makes the worker available again.

The OS core is the only owner of shared peripherals in this initial design. This avoids simultaneous access to the console or filesystem and makes the first inter-core protocol manageable.

## 4. Shell

The shell runs on Core 0 and reads commands from the ULX3S serial console. It supports the following ParticleMan commands:

### `list`

Print one row for each worker core, including its core number, state, and program name (and exit status when applicable). The OS core is identified separately as running ParticleMan.

Example:

```text
core  state    program
0     os       ParticleMan
1     running  hello
2     free     -
```

### `run <filename> [arguments...]`

Resolve the filename using the current working directory, load it from the SD card, and start it on a free worker core. Arguments after the filename are passed to the process in order. If no worker core is free, print an explicit error and do not load or start the program. Report file, format, or load errors without marking a core as running.

The executable image format, load address, and argument-passing ABI must be specified before implementing the loader. The initial format should be simple to validate and should identify at least the entry point, image size, and any required memory size.

### `kill [--force] <core-number>`

By default, request a cooperative stop from the process on the specified worker core. The process should reach a safe point, perform any supported cleanup, and exit through the normal termination path. Keep the core in `stopping` state until it exits. Report invalid core numbers and cores with no running process. Killing the OS core is not supported.

With `--force`, immediately stop the worker by asserting its reset, invalidate any outstanding OS request/response, and release the core for reuse. Forced termination may lose process state or unfinished filesystem operations.

### Basic filesystem commands

ParticleMan also provides basic file and directory operations through the same shell and SD-card-backed filesystem. The initial command set should include `ls`, `cd`, and `mkdir`; useful companion commands include `pwd`, `cat`, and `rm`. These are OS shell commands, not worker processes. They operate relative to the shell's current working directory.

The filesystem implementation and on-card format are implementation choices. Paths should be parsed consistently, and filesystem errors (missing path, invalid directory, full card, and I/O failure) should be printed rather than silently ignored.

## 5. Process lifecycle and traps

### Process exit: `trap 0`

On a worker launch, ParticleMan clears a per-core startup marker in reserved control state before releasing the core from reset. The worker's initial reset/startup path sets the marker once startup has begun. When vector 0 is entered, the handler consults this marker: the initial entry follows startup, while a later `trap 0` entry is treated as process termination. This uses the marker to distinguish the initial vector-0 startup from a software exit trap.

On termination, the worker stops executing user code, preserves or exposes the process exit status, and notifies ParticleMan. ParticleMan records the exit, releases process-owned resources, marks the core free, and reports completion to the shell. ParticleMan must clear the marker before every new worker launch and after a forced reset. This convention assumes worker resets are controlled by ParticleMan; any additional hardware reset-cause mechanism should be used to distinguish an unexpected reset from a software exit.

### OS service call: `trap 1`

When a process executes `trap 1`, it requests an OS service. The worker saves the request and its arguments in a per-core request area, notifies ParticleMan, and waits. ParticleMan validates and services the request (for example, console output or a filesystem operation), writes the result into the response area, and signals the worker. The worker restores its saved context, places the result in the agreed return registers, and resumes after the trap.

The request record should include a service number, argument values or a bounded argument block, and a request sequence/state field. The response should include a completion state, return value, and error code. The sequence/state field prevents the worker from consuming an old response. Shared-memory ordering and the notification mechanism must guarantee that request data is visible before notification and response data before resumption.

The OS core must not wait synchronously for a worker while that worker is waiting for an OS response. A worker awaiting a service is marked `waiting for OS`; ParticleMan services requests from its event loop and resumes the appropriate worker when its response is ready.

**Trap allocation:** Reserve software `trap 1` for synchronous OS service calls. Move inbound inter-core mailbox notifications from vector 1 to a separate hardware vector, proposed as vector 2, and reserve that vector for mailbox delivery. Update the vector map and mailbox routing accordingly. This avoids requiring a trap-cause register or overloading one handler with two unrelated protocols. Do not treat a mailbox interrupt as an OS API request merely because it was historically assigned vector 1.

## 6. Initial OS services

The first syscall set should stay small and synchronous:

| Service | Purpose |
|---|---|
| Console write | Send bytes to the serial console through the OS-owned UART |
| Console read | Obtain input from the serial console |
| File open/read/close | Read program images and application data from the SD card |
| File write | Optional initially; needed only if applications must create or modify files |
| Process exit | Prefer the dedicated `trap 0` termination path; an exit status is returned to the OS |

All service calls need defined argument types, buffer ownership and limits, return values, and error codes. For the first version, request buffers should reside in memory that ParticleMan can access and should have explicit maximum lengths.

## 7. Core states and failure behavior

The minimum worker state machine is:

```text
free -> loading -> running <-> waiting for OS -> stopping -> free
```

Loading failure returns the worker to `free`. An invalid syscall returns an error to the calling process rather than leaving it blocked. If a worker faults or stops responding, ParticleMan should report the core and failure state; automatic restart policy is outside the initial scope. A `kill` operation must clear or invalidate outstanding request/response state before reusing a core.

## 8. Initial scope and non-goals

**In scope**

- One ParticleMan OS core and one or more worker cores.
- A UART command shell.
- `list`, `run`, and `kill`.
- Basic SD-card filesystem commands.
- SD-card program loading.
- Process termination through the `trap 0` convention.
- Synchronous worker-to-OS calls through the `trap 1` convention.

**Deferred**

- Preemptive scheduling, time slicing, and multiple processes per core.
- Virtual memory, memory protection, and dynamic core migration.
- Background jobs, pipelines, shell scripting, and advanced filesystem features.
- Multiple concurrent users or direct worker access to shared devices.
- A general-purpose executable/linker format.

## 9. Source layout, configuration, and build plan

ParticleMan should be implemented as a separate system-on-chip design that reuses the Particle CPU, rather than as another Parcore pipeline. The existing Parcore Conductor is a separate architecture: it stages Parcore pipeline firmware from SPI flash. Its source, configuration, and flash image format are not ParticleMan's implementation.

### 9.1 Proposed repository layout

```text
hdl/
  particle/                       Existing reusable Particle CPU RTL and peripherals
  particleman/                    New ROHD package for the ParticleMan system
    lib/
      particleman_config.dart     System and per-core elaboration configuration
      particleman_top.dart        CPU cores, shared memory, reset, and peripheral wiring
      sd_card_controller.dart     SD-card host interface (if implemented in ROHD)
    test/                         ParticleMan integration and peripheral tests
    bin/
      generate_particleman.dart   Synthesizable SystemVerilog generator
firmware/
  particleman/                    OS-core startup and kernel firmware
apps/
  particleman/                    Example or user programs for the SD card
build/
  particleman/                    Generated firmware, image, and FPGA build outputs
```

`hdl/particle/lib` remains the source of the reusable `ParticleCpuCore` and existing Particle peripherals. The new `hdl/particleman` package owns the multi-core top-level, shared-memory/inter-core request plumbing, reset control, and board-level integration. It should depend on the existing Particle ROHD package in the same way `hdl/parcore` depends on it.

ParticleMan firmware belongs under `firmware/particleman`, separately from the existing `firmware/parcore` pipeline firmware. The OS startup image and kernel can initially be one firmware program; split shell, drivers, and syscall handling into separate files/modules as the firmware grows. Example user programs belong under `apps/particleman`; they are built as individual executables and copied into the SD-card filesystem image, not linked into the HDL generator.

The ULX3S top-level must connect the existing 3 Mbps FTDI UART hardware to ParticleMan's console path. The SD-card controller is new work: no SD-card host interface is currently part of the selected Particle CPU top-level. Add the controller at the system level and keep its registers, card-detect behavior (if available), and error reporting behind a ParticleMan driver. Do not treat the existing Parcore SPI-flash controller as an SD-card implementation.

### 9.2 Configuration model

Add a typed, compile-time `ParticleManConfig` in `hdl/particleman/lib/particleman_config.dart`. It should be the single source of truth for structural HDL choices and include:

| Setting | Initial proposal |
|---|---|
| Core count | At least 2 |
| OS core ID | 0 (physical core 0) |
| Worker core IDs | All configured cores other than core 0 |
| Per-core `CpuConfig` | Explicit core IDs, independently configurable TCM sizes, and any core features |
| Shared-memory/request area | Address range and size visible to the OS and workers |
| Console | ULX3S FTDI UART, initially 3 Mbps |
| SD-card host interface | Board-compatible interface and timing, to be selected |
| Boot image placement | OS image initialization/boot method and worker reset state |

Use the existing Particle `CpuConfig` for each `ParticleCpuCore`; do not duplicate CPU-level settings in an unrelated schema. `ParticleManConfig` should validate at construction or elaboration that there are at least two cores, physical core 0 exists and is reserved for the OS, IDs are unique, every core's memory size is configured, and required memory regions fit their configured limits.

Hardware-shaping values such as the number of cores and TCM sizes are elaboration-time configuration, not shell options. Keep OS-visible values (core IDs, memory map, syscall numbers, image format version, and peripheral addresses) synchronized with the firmware through a shared definition or a generated build manifest. Avoid maintaining independent, hand-edited copies of those constants.

The first build should have one named ULX3S configuration. Additional configurations (for example, different worker counts or simulation-only memory sizes) can be added as named presets once the initial board setup works. Preserve a clear distinction between the board-specific top-level and the reusable ParticleMan system so tests can instantiate the system without FPGA pin wiring.

### 9.3 Build and artifact flow

The repository already uses Dart/ROHD generators under `hdl/*/bin`, Dart tests under `hdl/*/test`, and a root Makefile for firmware and generation. Extend those conventions for ParticleMan:

1. **Build OS and user firmware.** Assemble ParticleMan assembly with the existing `pbuild`/`pasm` toolchain (or compile Action firmware if selected). Add root Makefile rules that place products under `build/particleman/`; do not put generated binaries beside checked-in sources. Compile example applications separately from the OS image.
2. **Package the SD-card contents.** Produce a documented card directory layout containing the executable applications and any needed data/filesystem metadata. If a reproducible card image is used instead of copying files, keep the image-generation tool and format definition with the ParticleMan build tooling. The runtime loader must consume the same executable format that the build produces.
3. **Generate HDL.** Add a `generate-particleman` root Makefile target that fetches the new package dependencies and runs `hdl/particleman/bin/generate_particleman.dart`. Write generated SystemVerilog to `hdl/particleman/particleman_top.sv` (matching existing per-package generator behavior) or another documented generated-output path; do not check generated artifacts in unless the repository's existing policy requires it.
4. **Synthesize and place-and-route.** Feed the generated SystemVerilog, ULX3S pin constraints, and selected ECP5 device/package settings to Yosys and `nextpnr-ecp5` from OSS CAD Suite. The root `make generate` target currently generates Particle and Parcore SystemVerilog only; generation is not FPGA synthesis or a bitstream build. Add separate ParticleMan FPGA targets so it is clear which outputs require the optional FPGA toolchain.
5. **Load and run on the board.** Document how the FPGA bitstream is programmed and how the SD card is prepared/inserted. Keep FPGA configuration/OS boot distinct from loading user programs at runtime: the OS starts from its defined boot image, while `run` reads an application from the SD card.

Add explicit root targets along the lines of `particleman-firmware`, `generate-particleman`, `test-particleman`, and (when the board flow is checked in) `build-particleman-fpga`. These are proposed targets, not commands currently available in the repository. Integrate `hdl/particleman` into `make setup` and `make clean`, and ensure cleanup only removes generated files under its build/output locations. The existing `make build` builds current Parcore firmware and applications; it does not yet build ParticleMan firmware.

### 9.4 Verification and implementation order

The implementation sequence should keep software, hardware, and generated artifacts aligned:

1. **Agree on architectural interfaces:** Resolve trap-vector conflicts, define process exit and syscall conventions, and specify shared-memory/mailbox visibility and core reset control.
2. **Create the ROHD system shell:** Add `hdl/particleman`, configuration validation, a multi-core top-level, per-core memories, and reset/worker control. Add a small elaboration test before connecting peripherals.
3. **Bring up OS-core I/O:** Connect the ULX3S FTDI UART and implement the SD-card host interface and driver; verify console input/output and card reads in tests before board testing.
4. **Implement shell and filesystem basics:** Add command parsing, current-directory handling, and `ls`, `cd`, and `mkdir`.
5. **Load a single worker process:** Define a minimal executable image and argument ABI; build a sample application, package it for the card, and load/start it on one worker core.
6. **Add lifecycle commands:** Implement `list`, `run`, `kill`, and process completion reporting, including no-free-core and load-failure cases.
7. **Add OS calls:** Implement the request/response protocol and `trap 1` services; verify a worker waits for a response and resumes with the result.
8. **Validate the complete system:** Exercise multiple workers, filesystem/console calls, normal exit, forced stop, and error paths in ROHD simulation, then synthesize and test the ULX3S build.

Add root Makefile integration for the new package and firmware as part of these milestones. Existing baseline commands are `make setup`, `make test-particle`, `make generate`, and `make build`; they do not yet test or generate ParticleMan. The ParticleMan targets should have focused test coverage for system elaboration, process loading/control, the syscall handshake, UART and SD-card behavior, and configuration/image mismatch errors.

## 10. Decisions

1. **Resolved:** Physical core 0 is reserved for ParticleMan. Memory size is independently configurable for every core.
2. **Resolved:** The worker's initial reset/startup path sets a per-core marker. A later vector-0 entry consults the marker and treats `trap 0` as process termination. ParticleMan clears the marker before launching or forcibly resetting a worker.
3. **Proposed:** Reserve software `trap 1` for OS calls and move hardware mailbox notifications to vector 2. This gives syscalls and mailbox events distinct vectors without requiring a new trap-cause register. Update the vector map and hardware routing to match.
4. **TBD:** Syscall register convention, request-buffer layout, and error-code set.
5. **TBD:** Executable image format and initial loader memory limits.
6. **TBD:** SD-card interface, filesystem/library, and supported command set.
7. **Resolved:** `kill <core-number>` requests cooperative termination by default. `kill --force <core-number>` forcibly resets the worker and discards any outstanding request/response state.
