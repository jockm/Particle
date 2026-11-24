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
- **RISC-V bare-metal toolchain** (optional), only for the official RISC-V
  ISA tests and for building or inspecting your own Parcore guest RV32IM_Zbb
  code (see [RISC-V development tools](#risc-v-development-tools)).
- **OSS CAD Suite** (optional), for FPGA synthesis and place-and-route on
  Lattice ECP5/ULX3S. It provides Yosys and `nextpnr-ecp5`; download the build
  for your platform from the [official OSS CAD Suite releases](https://github.com/YosysHQ/oss-cad-suite/releases).
  It is not needed for the Makefile targets, which generate SystemVerilog but
  do not synthesize or place-and-route it. See the
  [configuration guide](Documentation/configuration_guide.md).

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

For OSS CAD Suite, download the macOS build from the releases page above and
follow its instructions.

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
| OSS CAD Suite | `%USERPROFILE%\oss-cad-suite\bin` (used if present) |
| RISC-V toolchain | `%USERPROFILE%\xpack-riscv-none-elf-gcc\bin` (used if present) |

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

For OSS CAD Suite, download the Linux build from the releases page above and
follow its instructions.

### Checking the tools

Check that the commands are available in your shell (on Windows, in the
`pdev.cmd` shell):

```sh
git --version
dart --version
node --version
npm --version
python3 --version    # on Windows: python --version
code --version
clang --version      # only for the LLVM compiler
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