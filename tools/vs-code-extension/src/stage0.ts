import * as vscode from 'vscode';
import * as https from 'https';
import * as fs from 'fs';
import * as fsp from 'fs/promises';
import * as path from 'path';
import * as crypto from 'crypto';
import type { IncomingMessage } from 'http';

// Auto-managed stage0 compiler download.
//
// Per tools/vs-code-extension/README.md this file is VS Code integration glue,
// not language behavior: it only fetches the prebuilt `typelisp` stage0 binary
// that the LSP client launches as `typelisp lsp`. The actual compiler/LSP logic
// lives in the TypeLisp/selfhost code that produced the downloaded binary.
//
// The release layout mirrors scripts/fetch-stage0.{sh,ps1}:
//   https://github.com/<repo>/releases/download/<tag>/typelisp-stage0-linux
//   https://github.com/<repo>/releases/download/<tag>/typelisp-stage0-windows.exe
//   https://github.com/<repo>/releases/download/<tag>/SHA256SUMS
// The default `stage0-latest` tag is mutable: it is recreated on every push to
// main (see .github/workflows/bootstrap-stage0.yml), so refreshing it on
// startup keeps the editor on the newest compiler without any hardcoded path.

export interface Stage0Config {
  repo: string;
  releaseTag: string;
  autoUpdate: boolean;
}

type PlatformResult =
  | { supported: true; assetName: string; outputName: string; needsExec: boolean }
  | { supported: false; reason: string };

// Only Linux and Windows x86_64 stage0 binaries are published today. macOS and
// arm hosts have no asset, so we degrade gracefully instead of downloading a
// binary that cannot run.
export function resolvePlatform(): PlatformResult {
  const platform = process.platform;
  const arch = process.arch;

  if (platform === 'win32') {
    // x64 natively; arm64 Windows runs the x64 build under emulation.
    return {
      supported: true,
      assetName: 'typelisp-stage0-windows.exe',
      outputName: 'typelisp.exe',
      needsExec: false
    };
  }

  if (platform === 'linux') {
    if (arch !== 'x64') {
      return {
        supported: false,
        reason: `the published stage0 is x86_64 only, but this host is linux/${arch}`
      };
    }
    return {
      supported: true,
      assetName: 'typelisp-stage0-linux',
      outputName: 'typelisp',
      needsExec: true
    };
  }

  if (platform === 'darwin') {
    return {
      supported: false,
      reason: 'no macOS stage0 is published yet (only Linux and Windows x86_64 builds exist)'
    };
  }

  return { supported: false, reason: `unsupported platform ${platform}/${arch}` };
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// GET that follows GitHub's release-download redirects (github.com -> CDN).
function httpGet(url: string, redirectsLeft = 5): Promise<IncomingMessage> {
  return new Promise((resolve, reject) => {
    const request = https.get(
      url,
      { headers: { 'User-Agent': 'typelisp-vscode', Accept: '*/*' } },
      (response) => {
        const status = response.statusCode ?? 0;

        if (status >= 300 && status < 400 && response.headers.location) {
          response.resume();
          if (redirectsLeft <= 0) {
            reject(new Error(`too many redirects for ${url}`));
            return;
          }
          const next = new URL(response.headers.location, url).toString();
          httpGet(next, redirectsLeft - 1).then(resolve, reject);
          return;
        }

        if (status !== 200) {
          response.resume();
          reject(new Error(`HTTP ${status} for ${url}`));
          return;
        }

        resolve(response);
      }
    );

    request.on('error', reject);
    request.setTimeout(60_000, () => {
      request.destroy(new Error(`request timed out: ${url}`));
    });
  });
}

async function fetchText(url: string): Promise<string> {
  const response = await httpGet(url);
  const chunks: Buffer[] = [];
  for await (const chunk of response) {
    chunks.push(chunk as Buffer);
  }
  return Buffer.concat(chunks).toString('utf8');
}

async function downloadToFile(url: string, dest: string): Promise<void> {
  const response = await httpGet(url);
  await new Promise<void>((resolve, reject) => {
    const out = fs.createWriteStream(dest);
    response.on('error', reject);
    out.on('error', reject);
    out.on('finish', () => resolve());
    response.pipe(out);
  });
}

async function sha256File(filePath: string): Promise<string> {
  const hash = crypto.createHash('sha256');
  await new Promise<void>((resolve, reject) => {
    const stream = fs.createReadStream(filePath);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('error', reject);
    stream.on('end', () => resolve());
  });
  return hash.digest('hex');
}

// Parse a `sha256sum` manifest line for the given asset: "<64 hex>  <name>".
function expectedHashFor(sums: string, asset: string): string | undefined {
  for (const line of sums.split(/\r?\n/)) {
    const match = line.match(/^([0-9A-Fa-f]{64})\s+\*?(.+?)\s*$/);
    if (match && match[2] === asset) {
      return match[1].toLowerCase();
    }
  }
  return undefined;
}

async function fileExists(filePath: string): Promise<boolean> {
  try {
    await fsp.access(filePath);
    return true;
  } catch {
    return false;
  }
}

/**
 * Ensure a usable managed stage0 binary exists in the extension's global
 * storage and return its absolute path, or `undefined` if one could not be
 * provided (the caller then falls back to `typelisp` on PATH).
 *
 * On startup this only re-downloads the (multi-MB) binary when the upstream
 * SHA256SUMS shows it changed; an unchanged cached copy is reused. When the
 * network is unavailable the cached copy is reused as well.
 */
export async function ensureStage0(
  context: vscode.ExtensionContext,
  config: Stage0Config,
  log: vscode.OutputChannel,
  force = false
): Promise<string | undefined> {
  const platform = resolvePlatform();
  if (!platform.supported) {
    log.appendLine(`[stage0] auto-update skipped: ${platform.reason}`);
    return undefined;
  }

  const dir = path.join(context.globalStorageUri.fsPath, 'stage0');
  await fsp.mkdir(dir, { recursive: true });
  const dest = path.join(dir, platform.outputName);
  const baseUrl = `https://github.com/${config.repo}/releases/download/${config.releaseTag}`;
  const haveCached = await fileExists(dest);

  // Cheap freshness probe: the manifest is tiny, the binary is not.
  let expected: string | undefined;
  let manifestReachable = false;
  try {
    const sums = await fetchText(`${baseUrl}/SHA256SUMS`);
    expected = expectedHashFor(sums, platform.assetName);
    manifestReachable = true;
    if (!expected) {
      log.appendLine(`[stage0] SHA256SUMS does not list ${platform.assetName} yet`);
    }
  } catch (error) {
    log.appendLine(`[stage0] could not reach SHA256SUMS: ${describe(error)}`);
  }

  if (!force && haveCached && expected) {
    const actual = await sha256File(dest);
    if (actual === expected) {
      log.appendLine(`[stage0] up to date at ${dest}`);
      return dest;
    }
    log.appendLine('[stage0] cached binary is stale; downloading newer stage0');
  } else if (!force && haveCached && !manifestReachable) {
    log.appendLine(`[stage0] offline; reusing cached stage0 at ${dest}`);
    return dest;
  }

  const installed = await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: 'TypeLisp: downloading stage0 compiler',
      cancellable: false
    },
    () => downloadWithRetry(baseUrl, dir, dest, platform, expected, log)
  );

  if (installed) {
    return dest;
  }
  if (haveCached) {
    log.appendLine(`[stage0] download failed; reusing cached stage0 at ${dest}`);
    return dest;
  }
  return undefined;
}

async function downloadWithRetry(
  baseUrl: string,
  dir: string,
  dest: string,
  platform: Extract<PlatformResult, { supported: true }>,
  initialExpected: string | undefined,
  log: vscode.OutputChannel
): Promise<boolean> {
  const attempts = 4;

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    const tmp = path.join(dir, `.download.${process.pid}.${attempt}.tmp`);
    try {
      // Re-read the manifest each attempt: stage0-latest is republished by
      // delete-then-recreate, so the asset and its checksum can briefly come
      // from different generations. Refetching both rides out that window.
      let expected = initialExpected;
      try {
        expected = expectedHashFor(
          await fetchText(`${baseUrl}/SHA256SUMS`),
          platform.assetName
        ) ?? expected;
      } catch {
        // Keep whatever we had; verified-non-empty fallback below still applies.
      }

      log.appendLine(`[stage0] downloading ${platform.assetName} (attempt ${attempt}/${attempts})`);
      await downloadToFile(`${baseUrl}/${platform.assetName}`, tmp);

      const size = (await fsp.stat(tmp)).size;
      if (size <= 0) {
        throw new Error('downloaded asset is empty');
      }

      if (expected) {
        const actual = await sha256File(tmp);
        if (actual !== expected) {
          throw new Error(`sha256 mismatch: expected ${expected}, got ${actual}`);
        }
      } else {
        log.appendLine('[stage0] warning: SHA256SUMS unavailable; verified non-empty asset only');
      }

      // rename() cannot clobber an existing file on Windows.
      await fsp.rm(dest, { force: true });
      await fsp.rename(tmp, dest);
      if (platform.needsExec) {
        await fsp.chmod(dest, 0o755);
      }

      log.appendLine(`[stage0] installed ${dest}`);
      return true;
    } catch (error) {
      await fsp.rm(tmp, { force: true }).catch(() => undefined);
      log.appendLine(`[stage0] attempt ${attempt}/${attempts} failed: ${describe(error)}`);
      if (attempt < attempts) {
        await delay(1500);
      }
    }
  }

  return false;
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
