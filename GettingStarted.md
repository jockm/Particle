# Getting Started

This guide covers setting up the Particle tools, installing the VS Code
language extensions, building the project, and running its tests. Run the
commands below from the repository root unless a step says otherwise.

## Prerequisites

- **Dart SDK 3.x** for the Dart-based tools and ROHD hardware projects.
- **Node.js 20 or later**, including npm, to package the VS Code extensions.
- **Visual Studio Code** to install and use the extensions.
- **Python 3.8 or later** for Python-based project tools and test scripts.
- **Git** to clone the repository.
- **clang** (LLVM 15 or later), only to build Action programs for your own
  computer with the LLVM compiler (see [Building for your computer](#building-for-your-computer-llvm)).
  On macOS it comes with the Xcode Command Line Tools
  (`xcode-select --install`); on Linux, install your distribution's `clang`
  package.

Check that the commands are available in your shell:

```sh
dart --version
node --version
npm --version
python3 --version
code --version
clang --version      # only for the LLVM compiler
```

On macOS, if `code` is not found, open VS Code's Command Palette and run
**Shell Command: Install 'code' command in PATH**. The Makefile also checks
the standard macOS VS Code application location.

## Build and install VS Code support

Install both the Action (`.act`) and Particle assembly extensions from the
repository root:

```sh
make vscode-install
```

This Makefile target builds the Action and Particle language servers, then
packages and installs both VS Code extensions. While packaging, it runs
`npm install`, `npm run compile`, and `npx vsce package` in each extension's
directory. You do not need to run npm commands separately for a normal
installation. Reload open VS Code windows when the target finishes.

If `code` is unavailable, the target reports the issue. You can instead build
the extension packages with:

```sh
make vscode-ext
```

Then, in VS Code, use **Extensions: Install from VSIX…** to install
`build/action.vsix` and `build/particle.vsix`.

The extensions use the language servers built in `build/tools`. To build the
full command-line tool suite as well, run:

```sh
make tools
```

This builds the Action compiler, assembler, simulator, assembly linter, and
both language servers. Their Dart dependencies are fetched by the Makefile as
part of the builds (the first build needs internet access for that). The
Action compiler for LLVM is built separately, with `make llvm-tools`.

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
make test-parcore
make test-sim
```

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

### Optional LLVM tests

If you are working on the LLVM version of Action, run:

```sh
make llvm-tests
```

This builds the LLVM compiler if needed, builds the Action test programs for
this computer with clang, and runs them. Tests with the line
`//act:build particle`, which need Particle hardware, are skipped.

## Building for your computer (LLVM)

Action programs can also run on the computer you work on (64-bit macOS or
Linux). `make llvm-tools` builds the LLVM compiler
(`build/tools/action_llvm`), and the `llbuild` script at the repository root
compiles and links a program with clang:

```sh
make llvm-tools
./llbuild hello.act --run                  # builds build/llvm/hello and runs it
./llbuild main.act util.act -o build/llvm/app -O2
./llbuild app.act helpers.c -lm            # with C sources and libraries
```

The programs have debug information, so `lldb` or `gdb` can step through the
Action source. See section 2.10 of the Action language guide for the
options and for what differs from Particle, and section 2.11 for writing a
program for both Particle and LLVM.

## Useful Makefile commands

Run `make help` to see the available targets. Common ones include:

| Command | Purpose |
|---------|---------|
| `make tools` | Build all command-line tools and both language servers |
| `make llvm-tools` | Build the Action compiler for LLVM |
| `make vscode-install` | Build servers and extensions, then install the extensions |
| `make vscode-ext` | Build the VSIX packages without installing them |
| `make build` | Build firmware and applications |
| `make test` | Run Particle hardware, Parcore, and simulator tests |
| `make compiler-tests` | Run Action compiler, LSP, and Action program tests |
| `make test-lint` | Run assembly linter tests |
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
