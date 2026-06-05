import * as vscode from 'vscode';
import {
  Executable,
  LanguageClient,
  LanguageClientOptions,
  ServerOptions
} from 'vscode-languageclient/node';

const configSection = 'typelisp';
const languageId = 'typelisp';

let client: LanguageClient | undefined;
let restartQueue: Promise<void> = Promise.resolve();

export function activate(context: vscode.ExtensionContext): void {
  context.subscriptions.push(
    vscode.commands.registerCommand('typelisp.restartLanguageServer', () => {
      queueRestart();
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

async function restartLanguageClient(): Promise<void> {
  await stopLanguageClient();

  if (!languageServerEnabled()) {
    return;
  }

  const nextClient = createLanguageClient();
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

function createLanguageClient(): LanguageClient {
  const serverOptions = createServerOptions();
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

function createServerOptions(): ServerOptions {
  const executable = createServerExecutable();

  return {
    run: executable,
    debug: executable
  };
}

function createServerExecutable(): Executable {
  const config = vscode.workspace.getConfiguration(configSection);
  const command = trimmedOrDefault(
    config.get<string>('executablePath'),
    'typelisp'
  );
  const args = ['lsp', ...stdlibRootArgs(config.get<string[]>('stdlibRoots'))];
  const cwd = workspaceCwd();

  return {
    command,
    args,
    options: cwd ? { cwd } : undefined
  };
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
