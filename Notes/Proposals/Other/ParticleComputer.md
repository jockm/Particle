# Particle Computer: Single-Core System Proposal

**Status:** Proposal
**Target:** Lattice ECP5-85F ULX3S
**Initial memory:** 256 KiB total, configurable
**OS:** Single-tasking Particle OS written in Action

## 1. Summary

Particle Computer is a small, single-core computer built around one Particle CPU. A small bootloader is preloaded into on-chip memory. At reset, it initializes the board's serial console and SD-card interface, loads the Action-based OS from a FAT-formatted SD card, and transfers control to it.

The default 256 KiB memory map divides memory into a 64 KiB OS region and a 192 KiB user-program region. The total memory size is configurable at HDL elaboration time; the initial OS partition remains fixed at 64 KiB so user programs can always be linked for the fixed address `0x00010000`. The OS provides a simple command shell, a FAT32 filesystem, synchronous system calls through `trap 1`, and one foreground user program at a time.

The initial design favors straightforward bring-up over isolation or multitasking. User programs share physical memory with the OS and are trusted; hardware memory protection, background processes, and preemptive scheduling are out of scope.

## 2. Goals and scope

### Goals

- One Particle CPU with configurable on-chip memory; default capacity 256 KiB.
- A reset-time bootloader preloaded into the FPGA's memory initialization.
- The first 64 KiB reserved for boot code and the OS; the rest used for user programs.
- An Action OS loaded from the SD card at startup.
- The ULX3S-85F's 3 Mbps FTDI USB serial console.
- An SD-card interface and FAT filesystem support.
- A small, Linux-like command set and interactive shell.
- User programs written in Particle assembly or Action, stored on the SD card, and started in the foreground.
- A synchronous OS service ABI using Particle software `TRAP 1`.

### Non-goals for the first version

- Multiple concurrent processes, preemptive scheduling, or background jobs.
- Virtual memory, a process address-space abstraction, or strong OS/user isolation.
- Shell pipelines, job control, scripting, or full POSIX/Linux compatibility.
- Networking, multiple users, or a broad device-driver framework.

## 3. System architecture

```text
                  +------------------------------------+
                  | Particle Computer (single core)    |
                  |                                    |
                  |  Bootloader -> Action OS -> App    |
                  |        |              |            |
                  |        +-- shared BRAM             |
                  +----------+-------------------------+
                             |
              +--------------+---------------+
              |                              |
       3 Mbps FTDI UART                 SD-card SPI
       serial shell                     boot OS / FAT data
```

The board-specific top-level connects the Particle CPU, on-chip memory, UART, SD-card SPI pins, reset, and optional status LEDs. The bootloader and OS share the OS region. The OS loads one application into the user region, runs it, handles its system calls, then returns to the shell when it exits.

All new synthesizable hardware is to be described in Dart using ROHD and emitted as SystemVerilog. There should be no hand-maintained Verilog or SystemVerilog implementation for the new design. The Action OS, bootloader, and user applications are software firmware, not HDL.

## 4. Memory map and boot flow

### 4.1 Default layout

The address ranges below are byte-addressed. The total memory size is an elaboration-time configuration value.

| Address range | Default size | Purpose |
|---|---:|---|
| `0x00000000`–`0x000000FF` | 256 B | Zero page and boot metadata |
| `0x00000100`–`0x000004FF` | 1 KiB | Fixed trap vectors; reset at vector 0 and syscall trampoline at vector 1 |
| `0x00000500`–`0x00000FFF` | ~2.75 KiB | Remaining proposed bootloader code/data reservation |
| `0x00001000`–`0x0000FFFF` | 60 KiB | Action OS image, OS data, heap, and stack |
| `0x00010000`–`0x0003FFFF` | 192 KiB | User program image, data, heap, and stack |
| `0xF0000000` and above | — | Memory-mapped I/O window |

The bootloader reservation is an initial sizing proposal, not a hard architectural limit. Its actual size must be measured after implementing SD-card startup and vector dispatch. The first 64 KiB remains the OS allocation, including the bootloader; the Action OS image must fit in the portion left after boot and vector reservations.

For another configured total size `M`, the initial user region is `[0x00010000, M)`. The configuration must reject values too small to hold the bootloader, OS image, runtime data, and a useful user region. Changing the OS-region size would move the user load address and therefore requires a deliberate executable-ABI change and rebuilding all applications.

The implementation must define non-overlapping OS and user layouts for the image, static data, heap, and descending stack. The loader must reject an application whose image, memory requirements, or stack reservation exceed the configured user region. In the initial trusted-software model, these boundaries are enforced by the loader and conventions, not by a hardware privilege mode.

### 4.2 Boot sequence

1. FPGA configuration initializes the bootloader bytes in the Particle memory. Hardware reset enters the fixed reset vector in that bootloader.
2. The bootloader initializes the stack and the FTDI UART, then initializes the SD-card SPI interface.
3. A minimal boot-time FAT32 reader locates a fixed OS file, proposed as `/SYSTEM/PARTICLE.BIN`, and reads it into the OS load region. Start with short 8.3 filenames in the bootloader; the full FAT32 filesystem implementation belongs to the Action OS.
4. The bootloader validates the OS image header, load bounds, entry point, syscall-handler entry, and checksum before transferring control. The header should include a magic value, format version, image length, entry point, syscall-handler offset, and checksum. The bootloader writes the validated syscall-handler address into a fixed dispatch slot used by the vector-1 trampoline. On failure it prints a useful serial error and remains in a recovery loop rather than jumping into a partial image.
5. The Action OS initializes its heap, stack, filesystem state, and syscall dispatch, then presents the shell.
6. When the user starts a program, the OS reads it from the mounted FAT volume into the user region, initializes its stack and arguments, and transfers control to its entry point.
7. The program returns or calls the OS exit service through `trap 1`; the OS restores its shell context and prints the exit status.

The bootloader must retain a valid reset vector. The fixed syscall vector stub at `0x140` should save the user context, switch to the OS stack, and dispatch through a boot-metadata pointer to the validated Action handler in the loaded image. The OS image exports the handler offset in its header. This avoids requiring the OS binary to overwrite the reset code or vector table to install its handler.

## 5. HDL, board support, and configuration

### 5.1 Proposed source layout

```text
hdl/
  particle/                          Existing Particle CPU and reusable ROHD modules
  particle_computer/                 New ROHD package for this system
    lib/
      particle_computer_config.dart  Memory and board configuration
      particle_computer_top.dart     CPU, memory, UART, and SD-controller wiring
      sd_spi_controller.dart        SPI host controller and MMIO interface
    bin/
      generate.dart                  ROHD-to-SystemVerilog generator
    test/                            ROHD unit and system integration tests
firmware/
  particle_computer/
    boot/                            Preloaded reset/SD bootloader
    os/                              Action OS sources and startup code
apps/
  particle_computer/                 User programs in .act and .asm
lib/
  particle_computer/                 Shared Action API and assembly definitions
build/
  particle_computer/                 Generated firmware, SD image, SV, FPGA outputs
```

The new ROHD package should depend on and reuse the existing Particle CPU package. It should include a dedicated `ParticleComputerTop` rather than expanding `ParticleUlx3sTop`, which is currently a simple core/board wrapper and does not provide the complete boot-memory and SD-card system described here.

The current repository already contains a 3 Mbps `ParticleFtdiUart` module and an Action monitor example that uses Particle FIFO calls. The new top-level should connect the UART's ready/valid signals to the CPU/FIFO path and connect real memory; the current ULX3S wrapper's dummy memory and constant UART handshake wiring are not sufficient for this computer. The SD-card controller is new ROHD hardware.

### 5.2 HDL responsibilities

- Instantiate one `ParticleCpuCore` with a `CpuConfig` derived from the Particle Computer configuration.
- Infer the configured on-chip memory as FPGA block RAM. The 256 KiB default must be checked against the selected ECP5-85F's available EBR and the rest of the design's resource use.
- Connect the memory ports to the core and provide initialization bytes for the preloaded bootloader.
- Reuse the FTDI UART engine and bridge it to the core's console FIFO or a documented MMIO interface.
- Add a small ROHD SPI master for the ULX3S SD-card pins, with a simple register interface for command/data transfers and status.
- Decode the memory-mapped I/O window and return defined values for unmapped or invalid peripheral accesses.
- Export the board's clock, reset, FTDI, SD-card, and optional LED signals from the ULX3S top-level.

The SPI controller should implement byte transfers and chip-select/clock control; SD initialization, block-device logic, FAT parsing, and shell commands should be software in Action. This keeps policy and filesystem complexity out of HDL. Board pin assignments and electrical timing must be checked against the ULX3S-85F schematic and the chosen SD-card signaling mode.

### 5.3 Configuration

Add a typed, compile-time `ParticleComputerConfig` in `hdl/particle_computer/lib/particle_computer_config.dart`. Proposed fields include:

| Setting | Initial value or rule |
|---|---|
| `memorySizeBytes` | `256 * 1024` by default; configurable |
| `osRegionSizeBytes` | `64 * 1024`, fixed for the initial image ABI |
| `bootloaderSizeBytes` | Start with a 4 KiB budget; validate against the built image |
| `systemClockHz` | 25 MHz ULX3S clock |
| `consoleBaudRate` | 3,000,000 baud for the onboard FTDI UART |
| `sdSpiClockHz` | Configurable; use a conservative initialization speed and a supported transfer speed |
| `trapTableBase` / `trapStrideBytes` | Match the Particle architecture settings |
| `osImagePath` | `/SYSTEM/PARTICLE.BIN` |
| `userRegionBase` | Fixed at `0x00010000` |

Validate that the bootloader and OS fit in the OS region, the total memory extends beyond `0x00010000`, the configured memory is supported by the memory implementation, and addresses do not overlap the MMIO window. Peripherals should have one source of truth for register addresses shared with the Action driver definitions.

The total memory size is compile-time/HDL configuration, not a shell setting. The initial OS partition and user load address are fixed parts of the executable ABI. Image build tools must consume the same layout configuration as the HDL generator and firmware linker/assembler options, or consume a generated manifest, so changing `memorySizeBytes` cannot silently leave the OS or applications built for an incompatible layout.

## 6. Action OS design

The OS should be mostly Action source under `firmware/particle_computer/os`. Keep the reset-time loader small and in Particle assembly under `firmware/particle_computer/boot`, because it must run before the Action image is available. If Action startup support becomes sufficient for the entire loader, the assembly portion can later be reduced, but the fixed reset/vector entry remains explicit.

Organize the Action OS into small modules with narrow responsibilities:

- **Startup and kernel:** Initialize the Action runtime, OS stack, heap, memory map, and trap dispatcher.
- **Console driver:** Blocking line input and output through the FTDI UART; handle CR/LF and backspace.
- **SD block driver:** Issue commands and transfer 512-byte sectors through the SPI controller.
- **FAT layer:** Parse the partition/volume boot record, FAT allocation tables, directory entries, and file chains.
- **Path and file layer:** Track the current directory and provide open/read/close plus the small set of write operations needed by shell commands.
- **Shell:** Tokenize a line, resolve built-ins or an executable, call the appropriate OS operation, and report errors.
- **Program loader:** Validate the executable header and bounds, initialize arguments and stack, and enter the program.

For the first release, support FAT32 volumes with a documented partition layout. Support short 8.3 names first; VFAT long filenames can follow if the implementation budget permits. Support ordinary reads, directory listing, and writes for the selected shell commands, including `mkdir` and `rm`. FAT12, FAT16, exFAT, journaling, permissions, and POSIX semantics are not initial requirements. Boot-time FAT lookup must agree with the OS filesystem's FAT32 and filename rules.

The OS and applications share the single physical address space. A syscall handler should validate user pointers and lengths against the user-region bounds before reading or writing through them. This is a correctness guard, not a security boundary: without hardware privilege and write protection, a malicious or buggy application can still overwrite OS memory or MMIO.

## 7. System calls through `trap 1`

The Particle architecture currently assigns vector 1 by convention to inbound mailbox notifications. Particle Computer has one core and no mailbox peer, so this proposal repurposes vector 1 for the OS syscall ABI. Update the shared trap-vector documentation and constants before using this convention; there must not be a second interpretation of vector 1 in this single-core target.

Action supports `trap(1)` and Action trap-handler declarations. Define one OS handler at vector 1 and expose ordinary Action wrapper functions to applications. Applications should call wrappers such as `os_write`, `os_read`, `os_open`, and `os_exit`; a shared runtime/assembly bridge should handle register setup and trap entry so each application does not reimplement that ABI.

### Proposed syscall ABI

Use the existing Particle calling convention and keep the first version small:

| Register | On trap entry | On return |
|---|---|---|
| `R1` | System-call number | Primary result |
| `R2` | Argument 1 | Error code (`0` means success) |
| `R3` | Argument 2 | Available for a secondary result |
| `R4` | Argument 3 | Preserved or secondary result by service definition |
| `R14` | Trap return address, set by hardware | Restored as required by the trap-return sequence |
| `R15` | User stack pointer at trap entry | Restored before returning to the program |

For example, `write(fd, buffer, length)` uses `R1=WRITE`, `R2=fd`, `R3=buffer`, and `R4=length`; the handler returns the byte count in `R1` and an error code in `R2`. Define stable syscall numbers and error codes in the shared Action/assembly interface. Pass larger argument blocks through a user-memory pointer with a defined size and alignment.

The fixed vector-1 stub should switch from the user stack to a dedicated OS stack, save the user context needed for resumption, invoke the Action syscall dispatcher through the boot-metadata pointer, store the result, restore the user stack/context, and return to the instruction after `TRAP 1`. A small assembly entry/return shim is appropriate if the Action compiler's generated trap handler cannot safely switch stacks or preserve the required context by itself. Validate the exact convention with a round-trip test before implementing the full API.

Initial services should include console read/write, file open/read/close, directory operations needed by the shell, and process exit. File creation and writes can be added alongside `mkdir`, `rm`, or `cp` if those commands are included in the first shell.

Use a dedicated `EXIT` syscall (or an Action `os_exit(status)` wrapper) for a program to finish. Do not use `TRAP 0` for normal program exit: vector 0 remains the reset/boot entry, and the OS needs a controlled return to its shell.

## 8. Shell and user programs

### 8.1 Initial shell

The shell is single-tasking and foreground-only. A command launches one operation or program; the prompt returns when it completes. A useful initial command set is:

| Command | Purpose |
|---|---|
| `help` | List built-ins and usage |
| `pwd` | Print the current directory |
| `ls [path]` | List directory entries |
| `cd [path]` | Change the current directory |
| `cat <file>` | Print a text file |
| `mkdir <path>` | Create a directory |
| `rm <path>` | Remove a file, subject to FAT implementation support |
| `run <program> [args...]` | Load and run a program in the user region |
| `clear` | Clear the terminal, if supported by the terminal |

Executing a program by entering its filename may be added as a shortcut for `run`. Parse whitespace-separated arguments and quoted paths/arguments. Support absolute and relative paths, `.`, and `..`. Pipelines, redirection, wildcards, environment variables, and background execution are deferred; describe the shell as Linux-like in familiar commands, not as Linux-compatible.

### 8.2 Building programs

Support both Particle assembly and Action applications:

- Store assembly applications as `.asm` and Action applications as `.act` under `apps/particle_computer`.
- Build assembly using the existing `pbuild`/`pasm` workflow. Build Action with the existing Action compiler and `pbuild`.
- Provide a shared user-program startup/ABI library. Assembly programs include the published syscall macros and startup definitions; Action programs import or link the Action OS API wrappers.
- Link every application for the fixed user-region base `0x00010000`, not the normal reset address. Do not require position-independent code in the initial version; the loader rejects an executable built for a different base.
- Package each executable as a small versioned image with a magic value, required load address, image length, entry offset, BSS size, required stack size, and ABI version. The loader validates all fields and bounds before copying anything into user memory.
- On program start, pass arguments in a documented format (initially a count plus pointers/strings on the user stack), initialize the heap and stack within the user region, and jump to the entry point.
- On normal return, the startup shim invokes `os_exit` with the returned status. `os_exit` uses `trap 1` and never returns to the terminated program.

An Action application should use the shared OS API rather than access the SD controller directly; the API shape could be `os_write(fd, buffer, length)` and `os_exit(status)`. An assembly application includes the shared syscall definitions and issues `TRAP 1` with the same register ABI. For example:

```assembly
; R1 = syscall number, R2 = file descriptor, R3 = buffer, R4 = byte count
LOAD32  R1, SYS_WRITE
LD      R2, 1
LOAD32  R3, message
LD      R4, message_length
TRAP    1
; On return: R1 = bytes written, R2 = error code (0 on success)
```

The Action wrapper's exact source syntax and the assembly symbols should be finalized with the shared ABI, then covered by the same syscall round-trip tests.

The build should produce standalone executable files for the SD card. The OS and bootloader are built separately: the bootloader binary initializes FPGA memory, while the OS image and user executables are copied into the FAT volume.

## 9. Repository build and verification plan

The repository already has a root Makefile, Action and assembly tools, ROHD packages under `hdl`, generated SystemVerilog in each HDL package, and tests alongside the HDL. Extend these conventions rather than introducing a second build system.

### Proposed build products

```text
build/particle_computer/
  bootloader.bin
  os/particle.bin
  apps/<program>.pce
  sd-root/SYSTEM/PARTICLE.BIN
  sd-root/APPS/<program>.PCE
  particle_computer_top.sv
  fpga/                         Synthesis and place-and-route outputs
```

The SD-root directory is a convenient staging tree that can be copied to a FAT-formatted card. An optional reproducible disk image can be generated from it by a documented image-building target. Do not put generated binaries or bitstreams into source directories.

### Proposed root targets

- `make setup` — also fetch Dart dependencies for `hdl/particle_computer`.
- `make particle-computer-firmware` — build the reset bootloader, Action OS, and user applications into `build/particle_computer`.
- `make particle-computer-sd` — stage the OS and application files into the FAT card directory (and optionally create an image).
- `make generate-particle-computer` — run the ROHD generator and emit synthesizable SystemVerilog.
- `make test-particle-computer` — run the new ROHD and software integration tests.
- `make build-particle-computer-fpga` — run Yosys and `nextpnr-ecp5` with the ULX3S-85F constraints when the optional OSS CAD Suite is installed.

These are proposed targets; they do not currently exist. The existing root `make generate` generates the existing Particle and Parcore HDL, and `make build` builds existing firmware and applications. Neither currently produces a Particle Computer bitstream or SD-card image. Keep HDL generation distinct from synthesis/place-and-route and document the external FPGA tools and board programming step.

### Verification

1. ROHD unit tests for the SD SPI controller, memory initialization, address decoding, and UART bridge.
2. System simulation for reset, bootloader image presence, OS-region bounds, and syscall vector dispatch.
3. Host-side tests for executable headers, FAT directory/file loading, path parsing, and malformed-image errors where components can be tested independently.
4. Action/assembly integration tests that issue `trap 1`, receive a result, and return through `os_exit`.
5. Build-time checks that the bootloader fits its reserved region, the OS fits the configured OS partition, and every application fits the configured user region.
6. Synthesis and place-and-route checks for the ECP5-85F, followed by board tests for UART console operation, SD initialization, FAT reads/writes, and program execution.

## 10. Implementation phases

1. **Memory and boot contract:** Agree on configuration fields, default memory layout, executable/OS image headers, and reset/vector ownership.
2. **ROHD hardware foundation:** Add the configured single-core top-level, BRAM initialization, real memory wiring, UART bridge, SD SPI controller, and focused tests.
3. **Bootloader:** Build the small reset image, initialize the console and SD interface, locate and validate the OS image, and report failures over serial.
4. **Action kernel and console:** Load and start the Action OS, initialize runtime memory, implement the line editor and basic shell.
5. **Storage and FAT:** Add block reads/writes, FAT32 mounting, path traversal, directory listing, and the operations needed by initial commands.
6. **Trap-1 syscall path:** Implement and test the vector stub, OS stack/context save, Action dispatch, user wrapper library, error conventions, and exit service.
7. **User application loader:** Add the image format, build rules for `.act` and `.asm`, argument setup, bounds checks, and foreground return to the shell.
8. **Board packaging and release:** Add Make targets, SD-card staging, FPGA constraints/synthesis/programming instructions, and ULX3S-85F acceptance tests.

## 11. Decision record

1. **Resolved:** Total memory is configurable, with 256 KiB as the default. Keep the OS partition fixed at 64 KiB in the initial ABI.
2. **Resolved:** FAT32 only is required. The initial shell command set includes the listed filesystem operations, so the OS must support the corresponding FAT32 writes.
3. **Resolved:** Link applications for the fixed user load address `0x00010000`; include and validate the expected address in each executable image.
4. **Resolved:** The bootloader uses a minimal FAT32 reader to load `/SYSTEM/PARTICLE.BIN`; the Action OS provides the fuller FAT32 filesystem.
5. **Resolved:** The command set in Section 8.1 is approved for the initial shell.
6. **Open:** Specify quoting and escaping rules for command arguments and paths.
