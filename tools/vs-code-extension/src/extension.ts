import * as vscode from 'vscode';
import {
  Executable,
  LanguageClient,
  LanguageClientOptions,
  ServerOptions
} from 'vscode-languageclient/node';
import { Stage0Config, ensureStage0 } from './stage0';

const configSection = 'typelisp';
const languageId = 'typelisp';

let client: LanguageClient | undefined;
let restartQueue: Promise<void> = Promise.resolve();
let extensionContext: vscode.ExtensionContext | undefined;
let stage0Log: vscode.OutputChannel | undefined;

export function activate(context: vscode.ExtensionContext): void {
  extensionContext = context;
  stage0Log = vscode.window.createOutputChannel('TypeLisp Stage0');
  context.subscriptions.push(stage0Log);

  context.subscriptions.push(
    vscode.commands.registerCommand('typelisp.restartLanguageServer', () => {
      queueRestart();
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('typelisp.updateStage0', () => {
      void updateStage0Now();
    })
  );

  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration(configSection)) {
        queueRestart();
      }
    })
  );

  queueRestart();
}

export async function deactivate(): Promise<void> {
  await stopLanguageClient();
}

function queueRestart(): void {
  restartQueue = restartQueue.then(restartLanguageClient, restartLanguageClient);
  restartQueue.catch(reportClientError);
}

async function updateStage0Now(): Promise<void> {
  const context = extensionContext;
  if (!context) {
    return;
  }

  const config = vscode.workspace.getConfiguration(configSection);
  const cfg = readStage0Config(config);
  const path = await ensureStage0(context, cfg, stage0Log!, true);

  if (path) {
    void vscode.window.showInformationMessage(`TypeLisp stage0 updated: ${path}`);
  } else {
    void vscode.window.showWarningMessage(
      'TypeLisp could not download a managed stage0 compiler. See the "TypeLisp Stage0" output for details.'
    );
  }

  queueRestart();
}

async function restartLanguageClient(): Promise<void> {
  await stopLanguageClient();

  if (!languageServerEnabled()) {
    return;
  }

  const executable = await resolveServerExecutable();
  const nextClient = createLanguageClient(executable);
  client = nextClient;

  try {
    await nextClient.start();
  } catch (error) {
    if (client === nextClient) {
      client = undefined;
    }
    throw error;
  }
}

async function stopLanguageClient(): Promise<void> {
  const activeClient = client;
  client = undefined;

  if (activeClient) {
    await activeClient.stop();
  }
}

function createLanguageClient(executable: Executable): LanguageClient {
  const serverOptions: ServerOptions = {
    run: executable,
    debug: executable
  };
  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: 'file', language: languageId }],
    outputChannelName: 'TypeLisp Language Server',
    synchronize: {
      configurationSection: configSection,
      fileEvents: vscode.workspace.createFileSystemWatcher('**/*.tl')
    }
  };

  return new LanguageClient(
    'typelispLanguageServer',
    'TypeLisp Language Server',
    serverOptions,
    clientOptions
  );
}

async function resolveServerExecutable(): Promise<Executable> {
  const config = vscode.workspace.getConfiguration(configSection);
  const args = ['lsp', ...stdlibRootArgs(config.get<string[]>('stdlibRoots'))];
  const cwd = workspaceCwd();
  const options = cwd ? { cwd } : undefined;

  const command = await resolveServerCommand(config);

  return { command, args, options };
}

// Resolution order, designed so no path is hardcoded by default:
//   1. An explicitly configured `typelisp.executablePath` always wins (manual
//      override / escape hatch).
//   2. Otherwise, when `typelisp.stage0.autoUpdate` is on (default), download
//      and keep a managed stage0 in the extension's global storage.
//   3. Otherwise fall back to `typelisp` on PATH.
async function resolveServerCommand(
  config: vscode.WorkspaceConfiguration
): Promise<string> {
  const override = explicitExecutablePath(config);
  if (override) {
    return override;
  }

  const context = extensionContext;
  const cfg = readStage0Config(config);
  if (context && cfg.autoUpdate) {
    const managed = await ensureStage0(context, cfg, stage0Log!);
    if (managed) {
      return managed;
    }
  }

  return 'typelisp';
}

function readStage0Config(config: vscode.WorkspaceConfiguration): Stage0Config {
  return {
    autoUpdate: config.get<boolean>('stage0.autoUpdate', true),
    repo: trimmedOrDefault(config.get<string>('stage0.repo'), 'JoNil-Botta/typelisp'),
    releaseTag: trimmedOrDefault(config.get<string>('stage0.releaseTag'), 'stage0-latest')
  };
}

// Only treat `executablePath` as set when the user (or workspace) actually
// configured it; the default `"typelisp"` value must not suppress auto-update.
function explicitExecutablePath(
  config: vscode.WorkspaceConfiguration
): string | undefined {
  const inspected = config.inspect<string>('executablePath');
  const value =
    inspected?.workspaceFolderValue ??
    inspected?.workspaceValue ??
    inspected?.globalValue;
  const trimmed = value?.trim();
  return trimmed && trimmed.length > 0 ? trimmed : undefined;
}

function stdlibRootArgs(roots: string[] | undefined): string[] {
  const args: string[] = [];

  for (const root of roots ?? []) {
    const trimmed = root.trim();
    if (trimmed.length > 0) {
      args.push('--stdlib-root', trimmed);
    }
  }

  return args;
}

function languageServerEnabled(): boolean {
  const config = vscode.workspace.getConfiguration(configSection);
  return config.get<boolean>('enableLanguageServer', true);
}

function workspaceCwd(): string | undefined {
  const folders = vscode.workspace.workspaceFolders;
  return folders && folders.length > 0 ? folders[0].uri.fsPath : undefined;
}

function trimmedOrDefault(value: string | undefined, fallback: string): string {
  const trimmed = value?.trim();
  return trimmed && trimmed.length > 0 ? trimmed : fallback;
}

function reportClientError(error: unknown): void {
  const message = error instanceof Error ? error.message : String(error);
  void vscode.window.showErrorMessage(
    `TypeLisp language server failed to start: ${message}`
  );
}
