# action_lsp

Language server for Action. Editors start it and talk to it over stdin and
stdout using the Language Server Protocol. It uses the Action compiler
(`apps/tools/action`) as a library, so it reports exactly the errors the
compiler would.

Build it with `make action-lsp` (also part of `make tools`); it is written
to `build/tools/action_lsp`. The VS Code extension in `apps/tools/vscode/action` starts
it. Other editors can run `build/tools/action_lsp` as an LSP server for
`.act` files over stdio.

## What it does

| Request | |
|---------|--|
| `textDocument/publishDiagnostics` | The compiler's first error, after typing pauses (300 ms), on open and on save. Unsaved text is checked. |
| `textDocument/hover` | Types of variables, parameters and fields; function signatures; constant and enum values; type layouts; `//` comments above a declaration. |
| `textDocument/definition` | Locals, parameters, globals, functions, methods, types, fields, constants, enum members, and the file named by an `import`. |
| `textDocument/completion` | After `.`: fields, methods and built-in members. Elsewhere: names in scope, keywords, types and built-ins. |
| `textDocument/documentSymbol` | Functions, methods, tasks, trap handlers, types (with fields), enums (with members), globals, constants and aliases. |

While the current text does not parse, hover, definition, completion and the
outline use the last version that did.

The compiler's warnings and information are published with those
severities. A file checked on its own (not in a program listed in
`action.json`) may be compiled with files the server cannot see, so the
errors "is not declared" and "is declared but never defined" are shown as
information for it.

## Which files form a program

See `action.json` in `apps/tools/vscode/action/README.md`. Changes to `action.json` are
picked up when the editor reports them (VS Code does), and a mistake in it is
shown as an error on that file while the defaults are used.

## Layout

| File | |
|------|--|
| `bin/action_lsp.dart` | Entry point |
| `lib/src/connection.dart` | Message framing and JSON-RPC |
| `lib/src/server.dart` | Requests, notifications, documents and checking |
| `lib/src/project.dart` | `action.json` |
| `lib/src/symbols.dart` | Declarations of a checked program |
| `lib/src/features.dart` | Hover, definition, completion and outline |
| `lib/src/documents.dart` | Open documents, paths and positions |

Tests (`dart test`, also run by `make compiler-tests`) drive the server over
an in-memory connection.
