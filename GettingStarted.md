# Getting Started

This guide covers installing what the Particle tools need, getting the
source, building the tools, installing the VS Code language extensions,
building the project, and running its tests. Run the commands below from the
repository root unless a step says otherwise.

## Prerequisites

- **Git** to clone the repository, and for Action modules (`action --fetch`)
  and `make deps-tests`. Git is the only version control system supported.
- **Dart SDK 3.x** for the Dart-based tools and ROHD hardware projects.
- **Node.js 20 or later**, including npm, to package the VS Code extensions.
- **Visual Studio Code** to install and use the extensions.
- **Python 3.8 or later** for project tools and test scripts, including the
  Parcore guest-test generators that `make test` runs.
- **clang** (LLVM 15 or later), only to build Action programs for your own
  computer with the LLVM compiler (see
  [Building for your computer](#building-for-your-computer-llvm)), and for
  `make llvm-tests` and `make deps-tests`.
- **RISC-V bare-metal toolchain** (optional): a RISC-V GCC, or LLVM with the
  RISC-V target, for the official RISC-V ISA tests, the Parcore guest programs
  (`make parcore-bit`, `make parcore-profile`), and your own RV32IM_Zbb code
  (see [RISC-V development tools](#risc-v-development-tools)).
- **OSS CAD Suite** (optional): provides `yosys`, `nextpnr-ecp5`, `ecppack`,
  `openFPGALoader` and `verilator`. Yosys, nextpnr, `ecppack` and
  `openFPGALoader` build and load the ULX3S bitstreams (`make ulx3s-bit`,
  `make parcore-bit`, see the [configuration guide](Documentation/configuration_guide.md));
  Verilator runs the Parcore tests and `make parcore-profile` quickly
  (`make test-parcore` uses it by default). Download the build for your
  platform from the [official OSS CAD Suite releases](https://github.com/YosysHQ/oss-cad-suite/releases).
- **sv2v** (optional): converts ROHD's SystemVerilog to the Verilog-2001 that
  Xilinx ISE reads, for the Pano Logic G2 (`make uart-rohd-pano`). From the
  [sv2v releases](https://github.com/zachjs/sv2v/releases), or Homebrew.
- **Xilinx ISE 14.7** (optional), for the Pano Logic G2 (a Spartan-6 board):
  Xilinx's ISE VM for Windows 10 and 11, reached over ssh, with a Xilinx
  Platform Cable USB (or a clone) for JTAG, and a USB serial adapter that
  takes 5 V logic for its console. See
  [Setting up the ISE VM](#setting-up-the-ise-vm-for-the-pano-logic-g2).
- **Docker** (optional), for the OpenROAD ASIC RTL-to-GDS flow: it runs the
  official `openroad/orfs` container image identically across Windows, macOS
  and Linux, with no native OpenROAD compile needed. Particle doesn't have its
  OpenROAD flow yet (it is item 2 of [Road to GHz](Documentation/road_to_ghz.md));
  the sister project MicroRISC4 uses the same image for its `make asic-flow`,
  so one installation serves both.

## Installing dependencies

### macOS

Install the Xcode Command Line Tools, which provide `git`, `clang`, and
`python3`:

```sh
xcode-select --install
```

[Install Homebrew](https://brew.sh/) if needed, then install Dart, Node.js,
and VS Code:

```sh
brew tap dart-lang/dart
brew install dart
brew install node
brew install --cask visual-studio-code
```

For OSS CAD Suite, download the macOS (`arm64` or `x64`) archive from the
releases page above, extract it to `~/oss-cad-suite`, and add its `bin`
folder to your `PATH` (in `~/.zshrc`):

```sh
export PATH="$HOME/oss-cad-suite/bin:$PATH"
```

For the Pano Logic G2 builds, install sv2v:

```sh
brew install sv2v
```

### Windows

Install the tools with winget, from PowerShell or a Command Prompt:

```bat
winget install -e --id Git.Git
winget install -e --id MSYS2.MSYS2
winget install -e --id Google.DartSDK
winget install -e --id MartinStorsjo.LLVM-MinGW.UCRT
winget install -e --id OpenJS.NodeJS.LTS
winget install -e --id Microsoft.VisualStudioCode
winget install -e --id Python.Python.3.12
```

Git for Windows provides Git Bash, which the Makefile and the `pbuild` and
`llbuild` scripts need. Open a new terminal after installing, so it sees the
updated `PATH`.

Windows may also run `python.exe` and `python3.exe` as shortcuts that open
the Microsoft Store instead of Python. Turn them off: in **Settings → Apps →
Advanced app settings → App execution aliases**, switch off the
**App Installer** entries for `python.exe` and `python3.exe`.

For OSS CAD Suite, download the Windows build from the releases page above
and extract it to `%USERPROFILE%\oss-cad-suite`, so that its tools are in
`%USERPROFILE%\oss-cad-suite\bin`.

For the Pano Logic G2 builds, download the Windows build of sv2v from the
[sv2v releases](https://github.com/zachjs/sv2v/releases) and put `sv2v.exe`
in a folder on your `PATH`.

For the RISC-V toolchain, see
[RISC-V development tools](#risc-v-development-tools).

#### The development shell: `pdev.cmd`

On Windows, run every command in this guide from the shell that `pdev.cmd`
opens. `pdev.cmd`, at the repository root, finds the tools, puts them on
`PATH`, and opens a Git Bash shell in the repository root. Run it by
double-clicking it or from a Command Prompt:

```bat
pdev.cmd
```

It expects the tools in these places, which are where the winget commands
above put them:

| Tool | Where `pdev.cmd` looks |
|------|------------------------|
| Git Bash | `C:\Program Files\Git\bin\bash.exe` (required) |
| GnuWin32 (`make`) | `C:\Program Files (x86)\GnuWin32\bin` (required) |
| clang | `C:\Program Files\LLVM\bin`, then the WinGet LLVM-MinGW package (required) |
| Dart | The WinGet Dart SDK package, then `PATH` (required) |
| Node.js and npm | `%LOCALAPPDATA%\Programs\nodejs`, the WinGet Node.js package, then `C:\Program Files\nodejs` (required) |
| OSS CAD Suite | `%USERPROFILE%\oss-cad-suite\bin` and `\lib`, put ahead of Git Bash's own tools so Yosys and nextpnr load their own DLLs (used if present) |
| RISC-V toolchain | `%USERPROFILE%\xpack-riscv-none-elf-gcc\bin` (used if present) |
| Docker | `%ProgramFiles%\Docker\Docker\resources\bin`, then `PATH` (used if present) |
| Python, Git | Standard Windows `PATH` |

If a required tool is missing, `pdev.cmd` says which one and how to install
it. Python, VS Code's `code` command, and Git itself come from your normal
`PATH`.

### Linux

These steps are for Debian 12 or later and Ubuntu 24.04 or later, with apt.

Install Git, make, clang, Python, and what the next steps use:

```sh
sudo apt update
sudo apt install git make clang python3 curl gpg apt-transport-https
```

The LLVM compiler needs clang 15 or later. Ubuntu 24.04's `clang` is new
enough. Debian 12's `clang` is version 14, so on Debian 12 install a newer
one and tell the build to use it:

```sh
sudo apt install clang-16
export CLANG=clang-16    # add this to your ~/.bashrc as well
```

Install Dart from Google's apt repository:

```sh
wget -qO- https://dl-ssl.google.com/linux/linux_signing_key.pub \
  | sudo gpg --dearmor -o /usr/share/keyrings/dart.gpg
echo 'deb [signed-by=/usr/share/keyrings/dart.gpg arch=amd64] https://storage.googleapis.com/download.dartlang.org/linux/debian stable main' \
  | sudo tee /etc/apt/sources.list.d/dart_stable.list
sudo apt update
sudo apt install dart
```

(On an ARM computer, use `arch=arm64` instead of `arch=amd64`.)

The Node.js in Debian 12 and Ubuntu 24.04 is version 18, which is too old.
Install a current long-term-support version from NodeSource:

```sh
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt install nodejs
```

NodeSource's `nodejs` package includes npm.

For VS Code, download the `.deb` package from the
[VS Code download page](https://code.visualstudio.com/download) and install
it, which also adds Microsoft's apt repository for updates:

```sh
sudo apt install ./code_*.deb
```

For OSS CAD Suite, download the Linux archive from the releases page above,
extract it to `~/oss-cad-suite`, and add
`export PATH="$HOME/oss-cad-suite/bin:$PATH"` to your `~/.bashrc`.

For the Pano Logic G2 builds, download `sv2v-Linux.zip` from the
[sv2v releases](https://github.com/zachjs/sv2v/releases) and put the `sv2v`
binary in a folder on your `PATH` (such as `~/.local/bin`).

## Setting up the ISE VM for the Pano Logic G2

The Pano Logic G2's Spartan-6 is built with Xilinx ISE 14.7, which Xilinx
ships for Windows 10 and 11 as a VirtualBox VM running Linux. The Makefile's
`pano-*` targets run on your computer and drive the VM over ssh; see
[the Pano G2 notes](Documentation/panog2.md) and the
[configuration guide](Documentation/configuration_guide.md#the-pano-logic-g2).

1. Install the ISE 14.7 VM, with its free licence (it builds for the rev C
   board's XC6SLX100; a plain ISE WebPACK install on Linux may not support
   the part). The make targets expect ISE in
   `/opt/Xilinx/14.7/ISE_DS` (`PANO_ISE` otherwise).
2. In the VM, start the ssh server at boot, and give your computer an ssh
   host alias for it, `ise-vm` (`PANO_HOST` otherwise), in `~/.ssh/config`:
   the VM's port, user and key, and any options its old ssh server needs.
   `ssh ise-vm true` and `scp` to `ise-vm` must work without a password
   prompt.
3. Plug the JTAG cable in and pass it through to the VM (VirtualBox's USB
   settings); `make pano-vm-check` lists the board's JTAG chain from there.
4. The builds use `~/Projects/particle-pano` in the VM (`PANO_DIR`
   otherwise, relative to the VM's home directory).

`make pano-vm-check` checks all of this. The serial console needs an adapter
that takes 5 V logic, on your computer (see the wiring in the Pano G2
notes); `make pano-term` opens it.

## Installing Docker for the ASIC flow (OpenROAD-flow-scripts)

The OpenROAD ASIC RTL-to-GDS flow runs inside the official
`openroad/orfs` Docker image. That image already bundles OpenROAD, Yosys,
OpenSTA, KLayout, and public reference PDKs (`nangate45`, `asap7`, `sky130hd`,
`ihp-sg13g2`), so **all projects on your machine share one image** and you do
not need to clone or compile OpenROAD natively. Particle doesn't use it yet
(item 2 of [Road to GHz](Documentation/road_to_ghz.md)): skip this until its
flow arrives, or install it now if you use MicroRISC4.

### Windows (Docker Desktop + WSL2)

1. Enable **WSL2** if not already enabled (run PowerShell as Administrator,
   then reboot if prompted):

   ```powershell
   wsl --install --no-distribution
   ```

2. Install **Docker Desktop** via `winget`:

   ```powershell
   winget install -e --id Docker.DockerDesktop
   ```

3. Launch **Docker Desktop** from the Start menu, accept the prompts, and wait
   until the whale icon in the system tray shows **Engine running** (ensure
   **Settings → General → Use the WSL 2 based engine** is checked).
4. Open a fresh `pdev.cmd` shell and verify Docker works, then pull the shared
   OpenROAD-flow-scripts image once (~2–3 GB download, reused by all projects):

   ```sh
   docker --version
   docker run --rm hello-world
   docker pull openroad/orfs:latest
   ```

   If you work on the Windows computer over SSH and `docker pull` or
   `docker run` fails with `A specified logon session does not exist`, the
   Windows Credential Manager isn't available to SSH sessions. Turn off
   Docker's Windows credential helper for Docker Hub in
   `%USERPROFILE%\.docker\config.json` (public images pull without logging
   in):

   ```bat
   python -c "import json, os; p=os.path.expanduser('~/.docker/config.json'); d=json.load(open(p)); d.pop('credsStore', None); d['credHelpers']={'https://index.docker.io/v1/': ''}; json.dump(d, open(p,'w'), indent=2)"
   ```

### macOS

Choose either **Docker Desktop** (GUI) or **Colima** (lightweight open-source
CLI-only runtime via Homebrew):

* **Option A — Docker Desktop:**
  ```sh
  brew install --cask docker
  # Launch Docker.app once from Applications, then:
  docker pull openroad/orfs:latest
  ```
* **Option B — Lightweight CLI (`colima` + `docker`):**
  ```sh
  brew install colima docker
  colima start --cpu 4 --memory 8
  docker pull openroad/orfs:latest
  ```

### Linux (Ubuntu / Debian)

Install Docker Engine following the official Debian/Ubuntu packages and add
your user to the `docker` group:

```sh
sudo apt update
sudo apt install -y docker.io
sudo usermod -aG docker "$USER"
# Log out and back in (or run `newgrp docker`), then:
docker pull openroad/orfs:latest
```

### Checking the tools

Check that the commands are available in your shell (on Windows, in the
`pdev.cmd` shell):

```sh
git --version
dart --version
node --version
npm --version
python3 --version        # on Windows: python --version
code --version
clang --version          # only for the LLVM compiler
yosys -V                 # optional: OSS CAD Suite
nextpnr-ecp5 --version   # optional: OSS CAD Suite
verilator --version      # optional: OSS CAD Suite
sv2v --version           # optional: the Pano Logic G2 builds
ssh ise-vm true          # optional: the ISE VM, for the Pano Logic G2
docker --version         # optional: the OpenROAD flow
```

On Linux, `dart` may need a new terminal before it is found. On macOS, if `code` is not found, open VS Code's Command Palette and run
**Shell Command: Install 'code' command in PATH**. The Makefile also checks
the standard macOS VS Code application location.

## Get the source

Clone the repository and its submodules:

```sh
git clone https://github.com/jockm/Particle.git
cd Particle
git submodule update --init
```

If you cloned some other way, or skipped the submodule update, run:

```sh
git submodule update --init third_party/riscv-tests
```

On Windows, now run `pdev.cmd` in the new `Particle` folder and use the shell
it opens for the rest of this guide.

## Build the tools

```sh
make tools
```

This builds the Action compiler, assembler, simulator, assembly linter, and
both language servers into `build/tools`. Their Dart dependencies are fetched
by the Makefile as part of the builds (the first build needs internet access
for that). The Action compiler for LLVM is built separately, with
`make llvm-tools`.

## Build and install VS Code support

Install both the Action (`.act`) and Particle assembly extensions:

```sh
make vscode-install
```

This Makefile target builds the Action and Particle language servers if
needed, then packages and installs both VS Code extensions. While packaging,
it runs `npm install`, `npm run compile`, and `npx vsce package` in each
extension's directory. You do not need to run npm commands separately for a
normal installation. Reload open VS Code windows when the target finishes.

If `code` is unavailable, the target reports the issue. You can instead build
the extension packages with:

```sh
make vscode-ext
```

Then, in VS Code, use **Extensions: Install from VSIX…** to install
`build/action.vsix` and `build/particle.vsix`.

## Build project applications

To build the firmware and applications:

```sh
make build
```

The generated binaries are placed under `build/`. To generate synthesizable
SystemVerilog for the Particle and Parcore hardware:

```sh
make generate
```

`make generate` fetches the required Dart dependencies through `make setup`.
To fetch them explicitly, for example before working on hardware:

```sh
make setup
```

## Run tests

### Hardware and simulator tests

Run the overall hardware and simulator test suite:

```sh
make test
```

This runs the Particle ROHD tests, the Parcore pipeline regression tests, and
the instruction-level simulator test. The hardware targets fetch their Dart
dependencies through `make setup`.

To run just one part:

```sh
make test-particle
make test-particle-isa
make test-parcore
make test-sim
```

`make test-particle-isa` runs only the differential test: each program in
`hdl/particle/test/isa`, and a set of random programs, runs on both psim and
the ROHD core, and their registers and memory must match at the end. Pick the
random programs with `ISA_RANDOM_SEEDS`, for example
`make test-particle-isa ISA_RANDOM_SEEDS=1,2,3`.

### Action compiler and language-server tests

```sh
make compiler-tests
```

This builds the required Action and Particle tools, runs the Action compiler
unit tests and Action language-server tests, then builds and simulates the
Action compiler test programs. Test programs with the line `//act:build llvm`,
such as the floating-point test, use what only the LLVM compiler has and are
skipped.

### Assembly linter tests

```sh
make test-lint
```

This checks that valid assembly sources pass and that the negative lint
fixtures are rejected.

### Module tests

```sh
make deps-tests
```

This tests fetching, vendoring, and building with Action modules, on both
compilers. It needs Git and clang.

### Optional LLVM tests

If you are working on the LLVM version of Action, run:

```sh
make llvm-tests
```

This builds the LLVM compiler if needed, builds the Action test programs for
this computer with clang, and runs them. Tests with the line
`//act:build particle`, which need Particle hardware, are skipped.

### Official RISC-V ISA compliance tests (`riscv-tests`)

To verify Parcore against the 67 official RISC-V ISA architectural tests
(`rv32ui`, `rv32um`, and `rv32uzbb`), you need the RISC-V toolchain (see
[RISC-V development tools](#risc-v-development-tools)) and the
`third_party/riscv-tests` submodule (see [Get the source](#get-the-source)).
Then build the bare-metal test binaries and run the suite:

```sh
make test-parcore-isa
```

## Building for your computer (LLVM)

Action programs can also run on the computer you work on (64-bit macOS,
Linux or Windows; on Windows, use the LLVM installed in
[Installing dependencies](#windows) and the `pdev.cmd` shell). `make llvm-tools` builds the LLVM compiler
(`build/tools/action_llvm`), and the `llbuild` script at the repository root
compiles and links a program with clang:

```sh
make llvm-tools
./llbuild hello.act --run                  # builds build/llvm/hello and runs it
./llbuild main.act util.act -o build/llvm/app -O2
./llbuild app.act helpers.c -lm            # with C sources and libraries
```

The programs have debug information, so `lldb` or `gdb` can step through the
Action source. See section 2.10 of the
[Action language guide](Documentation/action-language-guide.md) for the
options and for what differs from Particle, and section 2.11 for writing a
program for both Particle and LLVM.

## RISC-V development tools

Parcore guest software targets RV32IM_Zbb. The bare-metal RISC-V compiler,
binutils, and debugger are needed for the official RISC-V ISA tests and for
building or inspecting your own guest RISC-V programs. They are not needed
for `make test`.

The toolchain's commands have a prefix that depends on where it comes from:
`riscv64-elf-` on macOS, `riscv64-unknown-elf-` on Linux, and
`riscv-none-elf-` on Windows. `make test-parcore-isa` finds any of them. Below,
`PREFIX-` stands for yours. Although some names contain `riscv64`, the
compiler targets the Parcore 32-bit ISA when given
`-march=rv32im_zbb -mabi=ilp32`. GCC 12 or later is needed for Zbb.

Either a RISC-V GCC or LLVM works for building: `apps/riscv/riscv_toolchain.sh`
uses GCC if it finds one and LLVM otherwise (`RISCV_TOOLCHAIN=gcc` or `llvm`
chooses; see [LLVM](#llvm) below). The rest of this section is about GCC.

### macOS

With Homebrew, run:

```sh
brew install riscv64-elf-gcc riscv64-elf-binutils riscv64-elf-gdb
```

### Linux

```sh
sudo apt install gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf gdb-multiarch
```

Ubuntu 24.04 has GCC 13. Ubuntu 22.04's is GCC 10, which is too old for Zbb.
The debugger is `gdb-multiarch`, which debugs RISC-V programs as well as
others.

### Windows

There is no winget package. Download the Windows zip
(`xpack-riscv-none-elf-gcc-<version>-win32-x64.zip`) of the latest
[xPack GNU RISC-V Embedded GCC release](https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases).
Extract it, then rename the folder it contains to `xpack-riscv-none-elf-gcc`
and move it to your user folder, so that the tools are in
`%USERPROFILE%\xpack-riscv-none-elf-gcc\bin`. `pdev.cmd` adds that folder to
`PATH` when it is there.

### Checking the toolchain

Check that the tools are installed, with your prefix:

```sh
PREFIX-gcc --version
PREFIX-as --version
PREFIX-objdump --version
PREFIX-gdb --version     # on Linux: gdb-multiarch --version
```

Verify that GCC accepts Parcore's target by compiling a small freestanding
object and disassembling it (on macOS, for example):

```sh
printf 'int add(int a, int b) { return a + b; }\n' | \
  riscv64-elf-gcc -march=rv32im_zbb -mabi=ilp32 -ffreestanding \
  -x c -c -o /tmp/parcore-rv32-check.o -
riscv64-elf-objdump -d -M no-aliases,numeric /tmp/parcore-rv32-check.o
```

Use the same `-march` and `-mabi` options when compiling Parcore guest
programs. `PREFIX-objdump -d -M no-aliases,numeric program.elf` is useful
for checking the generated instructions. `PREFIX-gdb program.elf` opens
the program with its symbols; stepping through execution additionally
requires a compatible RISC-V emulator or debug target.

### LLVM

LLVM with the RISC-V target, `ld.lld` and `llvm-objcopy` builds the guest
programs and the official ISA tests too. On macOS, `brew install llvm lld`
(Homebrew's `/opt/homebrew/opt/llvm/bin` and `lld` are found without being on
your `PATH`); on Linux, `sudo apt install clang lld llvm`. For an LLVM
elsewhere, set `RISCV_LLVM_BIN` to its `bin` folder. Three Zbb ISA tests
(`sext_b`, `sext_h`, `zext_h`) load 64-bit constants with `li`, which LLVM's
assembler rejects; the build keeps their low 32 bits, as GNU as does.

## Useful Makefile commands

Run `make help` to see the available targets. Common ones include:

| Command | Purpose |
|---------|---------|
| `make tools` | Build all command-line tools and both language servers |
| `make llvm-tools` | Build the Action compiler for LLVM |
| `make vscode-install` | Build servers and extensions, then install the extensions |
| `make vscode-ext` | Build the VSIX packages without installing them |
| `make build` | Build firmware and applications |
| `make setup` | Fetch the Dart dependencies for the hardware projects |
| `make generate` | Generate SystemVerilog for Particle and Parcore |
| `make test` | Run Particle hardware, Parcore, and simulator tests |
| `make test-parcore-isa` | Build and run official RISC-V ISA tests (`rv32ui`, `rv32um`, `rv32uzbb`) |
| `make compiler-tests` | Run Action compiler, LSP, and Action program tests |
| `make test-lint` | Run assembly linter tests |
| `make deps-tests` | Test fetching, vendoring, and building with Action modules |
| `make llvm-tests` | Build and run Action tests using the LLVM backend |
| `make clean` | Remove build outputs and generated hardware files |
| `make ulx3s-bit`, `make parcore-bit` | Build a ULX3S bitstream: one Particle core, or Parcore (OSS CAD Suite) |
| `make parcore-profile` | Profile Parcore running the benchmark guest (Verilator) |

## Developing a VS Code extension

The normal installation target handles npm dependencies and compilation. For
extension development, work in the extension's directory and compile or watch
it directly:

```sh
cd apps/tools/vscode/action
npm install
npm run compile
```

Use `npm run watch` instead of `npm run compile` for continuous compilation.
The Particle extension has the same commands under
`apps/tools/vscode/particle`.