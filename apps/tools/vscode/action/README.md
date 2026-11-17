# Action for VS Code

Language support for the Action language (`.act` files):

- Syntax highlighting
- Errors as you type, from the Action compiler itself
- Hover: a variable's type, a function's signature, a constant's value, a
  type's layout (field offsets and sizes)
- Go to definition, including across imports and onto an `import` line
  (a package's import goes to the first file of its folder)
- Completion: names in scope, keywords and types, fields and methods after
  `.`, and a package's `pub` names after its import name (`geo.`)
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
    "module": { "name": "github.com/you/project" },
    "includeDirs": ["lib", "apps/act"],
    "defines": { "DEBUG": 1, "BAUD": 115200 },
    "target": ["particle", "llvm"],
    "programFolders": ["apps/act/multi"],
    "programs": [
      { "files": ["tools/gen_main.act", "tools/gen_tables.act"] }
    ]
  }
}
```

Paths are relative to `action.json`. Each subfolder of a folder in
`programFolders` is one program: all the `.act` files in it are checked
together, and adding a folder or a file needs no change to `action.json`.
`programs` lists other groups file by file. A file in a program is checked
together with the rest of it; any other file is checked on its own.

`module` names the module, which programs made of packages need: a
package's import path is that name followed by the package's folder inside
`action.json`'s folder. A file that starts with a `package` line other than
`package main;` is checked together with the other files of its folder, as
that package. A package whose folder has another name than the package gets
a warning, and so does an import that is not used.

`target` is the compiler programs are checked for: `"particle"` (the
default), `"llvm"`, or both as a list. With both, an error found for only one
of them is shown as a warning that names it (`for llvm: ...`). A file with a
build directive such as `//act:build llvm` is checked for the targets it is
built for, and a file named for a target (`name_llvm.act`) that its directive
does not keep it to gets a warning.

Lines starting with `//act:build` are highlighted as build directives.

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
