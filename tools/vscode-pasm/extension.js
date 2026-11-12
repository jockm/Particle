// =============================================================================
// File: tools/vscode-pasm/extension.js
// Project: Particle RISC Architecture
// Description: Zero-dependency VS Code client for build/tools/pasm_lsp.
// =============================================================================

const vscode = require("vscode");
const cp = require("child_process");
const path = require("path");
const fs = require("fs");

class PasmLspClient {
  constructor(workspaceRoot, diagCollection, outputChannel) {
    this.workspaceRoot = workspaceRoot;
    this.diagCollection = diagCollection;
    this.output = outputChannel;
    this.proc = null;
    this.nextId = 1;
    this.pending = new Map();
    this.buffer = Buffer.alloc(0);
    this.expectedLength = null;
  }

  start() {
    const binPath = path.join(this.workspaceRoot, "build", "tools", "pasm_lsp");
    if (!fs.existsSync(binPath)) {
      this.output.appendLine(`[pasm_lsp] Binary not found at ${binPath}. Run 'make pasm-lsp' to build it.`);
      return false;
    }

    this.output.appendLine(`[pasm_lsp] Starting server: ${binPath}`);
    this.proc = cp.spawn(binPath, [], { cwd: this.workspaceRoot });

    this.proc.stdout.on("data", (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      this._processBuffer();
    });

    this.proc.stderr.on("data", (chunk) => {
      this.output.append(chunk.toString("utf8"));
    });

    this.proc.on("exit", (code) => {
      this.output.appendLine(`[pasm_lsp] Server exited with code ${code}`);
      this.proc = null;
    });

    this.sendRequest("initialize", {
      rootUri: vscode.Uri.file(this.workspaceRoot).toString(),
      rootPath: this.workspaceRoot,
    }).then(() => {
      this.sendNotification("initialized", {});
    });

    return true;
  }

  _processBuffer() {
    while (true) {
      if (this.expectedLength === null) {
        const headerEnd = this.buffer.indexOf("\r\n\r\n");
        if (headerEnd === -1) return;
        const headerStr = this.buffer.subarray(0, headerEnd).toString("ascii");
        const match = /Content-Length:\s*(\d+)/i.exec(headerStr);
        this.buffer = this.buffer.subarray(headerEnd + 4);
        if (!match) continue;
        this.expectedLength = parseInt(match[1], 10);
      }

      if (this.buffer.length < this.expectedLength) return;
      const bodyBytes = this.buffer.subarray(0, this.expectedLength);
      this.buffer = this.buffer.subarray(this.expectedLength);
      this.expectedLength = null;

      try {
        const msg = JSON.parse(bodyBytes.toString("utf8"));
        this._handleMessage(msg);
      } catch (err) {
        this.output.appendLine(`[pasm_lsp] JSON parse error: ${err}`);
      }
    }
  }

  _handleMessage(msg) {
    if (msg.method === "textDocument/publishDiagnostics" && msg.params) {
      const uri = vscode.Uri.parse(msg.params.uri);
      const diags = (msg.params.diagnostics || []).map((d) => {
        const range = new vscode.Range(
          d.range.start.line,
          d.range.start.character,
          d.range.end.line,
          d.range.end.character
        );
        const severity =
          d.severity === 1
            ? vscode.DiagnosticSeverity.Error
            : vscode.DiagnosticSeverity.Warning;
        const diag = new vscode.Diagnostic(range, d.message, severity);
        diag.source = d.source || "pasm";
        return diag;
      });
      this.diagCollection.set(uri, diags);
      return;
    }

    if (msg.id !== undefined && this.pending.has(msg.id)) {
      const { resolve, reject } = this.pending.get(msg.id);
      this.pending.delete(msg.id);
      if (msg.error) {
        reject(new Error(msg.error.message));
      } else {
        resolve(msg.result);
      }
    }
  }

  _send(payload) {
    if (!this.proc || !this.proc.stdin.writable) return;
    const body = Buffer.from(JSON.stringify(payload), "utf8");
    const header = Buffer.from(`Content-Length: ${body.length}\r\n\r\n`, "ascii");
    this.proc.stdin.write(Buffer.concat([header, body]));
  }

  sendRequest(method, params) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this._send({ jsonrpc: "2.0", id, method, params });
    });
  }

  sendNotification(method, params) {
    this._send({ jsonrpc: "2.0", method, params });
  }

  stop() {
    if (this.proc) {
      this.proc.kill();
      this.proc = null;
    }
  }
}

let client = null;

function activate(context) {
  const output = vscode.window.createOutputChannel("Particle PASM LSP");
  const diagCollection = vscode.languages.createDiagnosticCollection("particle-asm");
  context.subscriptions.push(output, diagCollection);

  const folders = vscode.workspace.workspaceFolders;
  if (!folders || folders.length === 0) return;
  const rootPath = folders[0].uri.fsPath;

  client = new PasmLspClient(rootPath, diagCollection, output);
  if (!client.start()) return;

  const isPasmDoc = (doc) => doc && doc.languageId === "particle-asm";

  // Sync already-open documents
  vscode.workspace.textDocuments.forEach((doc) => {
    if (isPasmDoc(doc)) {
      client.sendNotification("textDocument/didOpen", {
        textDocument: {
          uri: doc.uri.toString(),
          languageId: doc.languageId,
          version: doc.version,
          text: doc.getText(),
        },
      });
    }
  });

  context.subscriptions.push(
    vscode.workspace.onDidOpenTextDocument((doc) => {
      if (isPasmDoc(doc)) {
        client.sendNotification("textDocument/didOpen", {
          textDocument: {
            uri: doc.uri.toString(),
            languageId: doc.languageId,
            version: doc.version,
            text: doc.getText(),
          },
        });
      }
    }),
    vscode.workspace.onDidChangeTextDocument((e) => {
      if (isPasmDoc(e.document)) {
        client.sendNotification("textDocument/didChange", {
          textDocument: {
            uri: e.document.uri.toString(),
            version: e.document.version,
          },
          contentChanges: [{ text: e.document.getText() }],
        });
      }
    }),
    vscode.workspace.onDidSaveTextDocument((doc) => {
      if (isPasmDoc(doc)) {
        client.sendNotification("textDocument/didSave", {
          textDocument: { uri: doc.uri.toString() },
          text: doc.getText(),
        });
      }
    }),
    vscode.workspace.onDidCloseTextDocument((doc) => {
      if (isPasmDoc(doc)) {
        client.sendNotification("textDocument/didClose", {
          textDocument: { uri: doc.uri.toString() },
        });
      }
    })
  );

  // Hover Provider
  context.subscriptions.push(
    vscode.languages.registerHoverProvider("particle-asm", {
      async provideHover(doc, pos) {
        const res = await client.sendRequest("textDocument/hover", {
          textDocument: { uri: doc.uri.toString() },
          position: { line: pos.line, character: pos.character },
        });
        if (!res || !res.contents) return null;
        const md = new vscode.MarkdownString(res.contents.value);
        if (res.range) {
          const r = new vscode.Range(
            res.range.start.line,
            res.range.start.character,
            res.range.end.line,
            res.range.end.character
          );
          return new vscode.Hover(md, r);
        }
        return new vscode.Hover(md);
      },
    })
  );

  // Definition Provider
  context.subscriptions.push(
    vscode.languages.registerDefinitionProvider("particle-asm", {
      async provideDefinition(doc, pos) {
        const res = await client.sendRequest("textDocument/definition", {
          textDocument: { uri: doc.uri.toString() },
          position: { line: pos.line, character: pos.character },
        });
        if (!res || !res.uri) return null;
        return new vscode.Location(
          vscode.Uri.parse(res.uri),
          new vscode.Range(
            res.range.start.line,
            res.range.start.character,
            res.range.end.line,
            res.range.end.character
          )
        );
      },
    })
  );

  // DocumentSymbol Provider (Outline & Breadcrumbs)
  context.subscriptions.push(
    vscode.languages.registerDocumentSymbolProvider("particle-asm", {
      async provideDocumentSymbols(doc) {
        const res = await client.sendRequest("textDocument/documentSymbol", {
          textDocument: { uri: doc.uri.toString() },
        });
        if (!Array.isArray(res)) return [];
        const toVsSymbol = (s) => {
          const kindMap = {
            12: vscode.SymbolKind.Function,
            13: vscode.SymbolKind.Variable,
            14: vscode.SymbolKind.Constant,
          };
          const range = new vscode.Range(
            s.range.start.line,
            s.range.start.character,
            s.range.end.line,
            s.range.end.character
          );
          const selRange = new vscode.Range(
            s.selectionRange.start.line,
            s.selectionRange.start.character,
            s.selectionRange.end.line,
            s.selectionRange.end.character
          );
          const sym = new vscode.DocumentSymbol(
            s.name,
            s.detail || "",
            kindMap[s.kind] || vscode.SymbolKind.Variable,
            range,
            selRange
          );
          if (Array.isArray(s.children)) {
            sym.children = s.children.map(toVsSymbol);
          }
          return sym;
        };
        return res.map(toVsSymbol);
      },
    })
  );

  // Completion Provider
  context.subscriptions.push(
    vscode.languages.registerCompletionItemProvider(
      "particle-asm",
      {
        async provideCompletionItems(doc) {
          const res = await client.sendRequest("textDocument/completion", {
            textDocument: { uri: doc.uri.toString() },
          });
          if (!Array.isArray(res)) return [];
          const kindMap = {
            3: vscode.CompletionItemKind.Function,
            6: vscode.CompletionItemKind.Variable,
            14: vscode.CompletionItemKind.Keyword,
            21: vscode.CompletionItemKind.Constant,
          };
          return res.map((item) => {
            const ci = new vscode.CompletionItem(
              item.label,
              kindMap[item.kind] || vscode.CompletionItemKind.Keyword
            );
            if (item.detail) ci.detail = item.detail;
            if (item.documentation && item.documentation.value) {
              ci.documentation = new vscode.MarkdownString(item.documentation.value);
            }
            return ci;
          });
        },
      },
      ".",
      " ",
      ","
    )
  );
}

function deactivate() {
  if (client) {
    client.stop();
    client = null;
  }
}

module.exports = { activate, deactivate };
