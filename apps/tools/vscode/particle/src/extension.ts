// Particle extension: Particle RISC assembly (pasm). Starts the assembly
// language server (pasm_lsp) for particle-asm files and connects VS Code to
// it.

import * as fs from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from 'vscode-languageclient/node';

const exe = process.platform === 'win32' ? 'pasm_lsp.exe' : 'pasm_lsp';

let client: LanguageClient | undefined;

function workspaceFolder(): string | undefined {
  return vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
}

/** The first directory on PATH holding [name], or undefined. */
function onPath(name: string): string | undefined {
  for (const dir of (process.env.PATH ?? '').split(path.delimiter)) {
    if (dir === '') continue;
    const candidate = path.join(dir, name);
    if (fs.existsSync(candidate)) return candidate;
  }
  return undefined;
}

/**
 * Where the server is: the setting; else build/tools/pasm_lsp in the
 * workspace; else pasm_lsp on PATH. Returns what was tried when it is not
 * found.
 */
function findServer(): { path?: string; tried: string[] } {
  const folder = workspaceFolder();
  const configured = vscode.workspace
    .getConfiguration('particle.pasm')
    .get<string>('serverPath', '')
    .trim();
  if (configured !== '') {
    let p = configured.replace(/\$\{workspaceFolder\}/g, folder ?? '');
    if (!path.isAbsolute(p) && folder) p = path.join(folder, p);
    return fs.existsSync(p) ? { path: p, tried: [p] } : { tried: [p] };
  }
  const tried: string[] = [];
  if (folder) {
    const inWorkspace = path.join(folder, 'build', 'tools', exe);
    tried.push(inWorkspace);
    if (fs.existsSync(inWorkspace)) return { path: inWorkspace, tried };
  }
  tried.push(`${exe} on PATH`);
  const found = onPath(exe);
  return found ? { path: found, tried } : { tried };
}

async function startServer(): Promise<void> {
  const server = findServer();
  if (!server.path) {
    void vscode.window.showErrorMessage(
      `The Particle assembly language server was not found (looked for ${server.tried.join(', then ')}). ` +
        "Run 'make pasm-lsp', or set 'particle.pasm.serverPath'.",
    );
    return;
  }
  const serverOptions: ServerOptions = {
    command: server.path,
    args: [],
    options: { cwd: workspaceFolder() },
  };
  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: 'file', language: 'particle-asm' }],
  };
  client = new LanguageClient(
    'particle.pasm',
    'Particle Assembly Language Server',
    serverOptions,
    clientOptions,
  );
  await client.start();
}

async function stopServer(): Promise<void> {
  const c = client;
  client = undefined;
  if (c) {
    await c.stop();
  }
}

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  context.subscriptions.push(
    vscode.commands.registerCommand('particle.pasm.restartServer', async () => {
      await stopServer();
      await startServer();
    }),
    vscode.workspace.onDidChangeConfiguration(async (e) => {
      if (e.affectsConfiguration('particle.pasm.serverPath')) {
        await stopServer();
        await startServer();
      }
    }),
  );
  await startServer();
}

export async function deactivate(): Promise<void> {
  await stopServer();
}
