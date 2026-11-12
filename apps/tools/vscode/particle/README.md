# Particle for VS Code

Language support for Particle RISC assembly (pasm):

- Syntax highlighting
- Errors and lint warnings as you type, from pasm and pasm_lint
- Hover, go to definition, find references, rename, completion and an
  outline

The language is `particle-asm`. The extension itself claims `.pasm` files;
to use it for `.asm` and `.inc` files in a project, map them in that
project's `.vscode/settings.json`:

```json
{
  "files.associations": {
    "*.asm": "particle-asm",
    "*.inc": "particle-asm"
  }
}
```

(`.asm` is used by many assemblers, so the extension does not claim it
everywhere.)

It starts the assembly language server, `pasm_lsp`, which it looks for in
this order:

1. the setting **Particle › Pasm: Server Path** (`particle.pasm.serverPath`);
2. `build/tools/pasm_lsp` in the workspace folder (`make pasm-lsp`, part of
   `make tools`);
3. `pasm_lsp` on your `PATH`.

After rebuilding the server, run **Particle: Restart Assembly Language
Server** from the command palette.

## Installing

```sh
make vscode-install
```

builds the servers and both extensions (Action and Particle) and installs
them. Then reload any open VS Code windows. Needs Node.js 20 or later and
npm.

## Developing the extension

```sh
cd apps/tools/vscode/particle
npm install
npm run compile     # or: npm run watch
```

Press F5 in VS Code with this folder open to start a window running the
extension.

## Node.js versions

`package.json` pins (under `overrides`) the versions of some packages that
the packaging tool `vsce` pulls in, so the extension can be packaged with
Node.js 20 as well as 22. Newer releases of those packages require Node.js 22.
