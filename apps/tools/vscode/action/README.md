# Action for VS Code

Language support for the Action language (`.act` files):

- Syntax highlighting
- Errors as you type, from the Action compiler itself
- Hover: a variable's type, a function's signature, a constant's value, a
  type's layout (field offsets and sizes)
- Go to definition, including across imports and onto an `import` line
- Completion: names in scope, keywords and types, and fields and methods
  after `.`
- Outline of a file's functions, types, constants and enums
- Checking of the project file `action.json`

It starts the Action language server, `action_lsp`, which it looks for in
this order:

1. the setting **Action: Server Path** (`action.serverPath`);
2. `build/tools/action_lsp` in the workspace folder (the Particle project
   builds it there with `make tools`);
3. `action_lsp` on your `PATH`.

After rebuilding the server, run **Action: Restart Language Server** from
the command palette.

## Installing (Particle project)

```sh
make vscode-install
```

builds the servers and both extensions (Action and Particle) and installs
them. Then reload any open VS Code windows. `make vscode-ext` only builds
the `.vsix` files (`build/action.vsix`, `build/particle.vsix`). Both need
Node.js 20 or later and npm.

## The project file

The editor checks each file as the compiler would. By default a file is
checked with what it imports, searching the file's own directory, the
workspace root and `lib`. Programs built from several files on the command
line, include directories and `-D` values are described in `action.json` at
the workspace root:

```json
{
  "action": {
    "includeDirs": ["lib", "apps/act"],
    "defines": { "DEBUG": 1, "BAUD": 115200 },
    "programs": [
      { "files": ["apps/act/multi_file_main.act", "apps/act/multi_file_math.act"] }
    ]
  }
}
```

Paths are relative to `action.json`. A file listed in a program is checked
together with the rest of it.

## Developing the extension

```sh
cd apps/tools/vscode/action
npm install
npm run compile     # or: npm run watch
```

Press F5 in VS Code with this folder open to start a window running the
extension.

## Node.js versions

`package.json` pins (under `overrides`) the versions of some packages that
the packaging tool `vsce` pulls in, so the extension can be packaged with
Node.js 20 as well as 22. Newer releases of those packages require Node.js 22.
