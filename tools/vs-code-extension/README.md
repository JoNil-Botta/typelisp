# TypeLisp VS Code Extension

First-party VS Code extension for the TypeLisp language (#922).

## Install from GitHub Releases

The Bootstrap Stage0 workflow packages this extension as `typelisp.vsix` and
attaches it to the same `stage0-latest` release as the compiler, so it installs
from a stable URL — no marketplace and no local checkout required. Combined with
the runtime stage0 auto-download, the `.vsix` is fully self-contained.

```sh
# With the GitHub CLI:
gh release download stage0-latest -R JoNil-Botta/typelisp -p typelisp.vsix
code --install-extension typelisp.vsix --force

# Or with curl:
curl -fsSL -o typelisp.vsix \
  https://github.com/JoNil-Botta/typelisp/releases/download/stage0-latest/typelisp.vsix
code --install-extension typelisp.vsix --force
```

`--force` reinstalls even when the version number is unchanged (the extension
rarely bumps its version since the compiler is fetched at runtime). The
`stage0-latest` asset is republished on every push to `main`, so re-running the
install above always lands the newest build.

## Non-TypeLisp Code Exception

Per the #922 decision, the editor-extension glue under
`tools/vs-code-extension/` is an explicit, narrow exception to the "new project
code should be TypeLisp" rule: VS Code cannot load extensions written in
TypeLisp. The exception covers only VS Code integration glue: language
registration, TextMate grammar packaging, LSP client wiring, commands, and
packaging metadata.

Compiler, formatter, parser, diagnostics, and LSP server behavior stay in
TypeLisp/selfhost code and must not be reimplemented here. Language analysis
comes from the TypeLisp LSP server (`typelisp lsp`); this extension is only a
client.

## What This Provides

- Registers `.tl` files as the `typelisp` language.
- Syntax highlighting (`syntaxes/typelisp.tmLanguage.json`) for TypeLisp
  comments, strings, character literals, numbers, special forms, constants,
  built-in type names, operators, and definition names.
- `language-configuration.json` for comment toggling, bracket matching, and
  auto-closing pairs.
- A `vscode-languageclient` activation layer that starts `typelisp lsp` over
  stdio for `typelisp` documents when `typelisp.enableLanguageServer` is true.
- Automatic download of the prebuilt `typelisp` stage0 compiler from GitHub
  releases, so the LSP runs out of the box without a hardcoded compiler path.
- The `TypeLisp: Restart Language Server` and `TypeLisp: Update Stage0 Compiler`
  commands.
- npm scripts for TypeScript compilation and VSIX packaging smoke.

## Stage0 Compiler Auto-Update

The LSP server is just `typelisp lsp`, so the extension needs a `typelisp`
binary. Rather than hardcoding a path, it downloads the published stage0
compiler on startup and keeps it current:

- The binary is stored in the extension's **global storage**
  (`context.globalStorageUri`, e.g. on Windows
  `%APPDATA%\Code\User\globalStorage\typelisp.typelisp\stage0\`). This is
  per-user, shared across workspaces, and removed when the extension is
  uninstalled — nothing is written into your project or onto a fixed path.
- On startup it fetches the tiny `SHA256SUMS` manifest for the tracked release
  and compares it to the cached binary, only re-downloading the (multi-MB)
  compiler when it actually changed. The download is checksum-verified, retries
  through the `stage0-latest` republish window, and the cached copy is reused
  when offline.
- The asset is selected for the current platform
  (`typelisp-stage0-windows.exe` on Windows, `typelisp-stage0-linux` on Linux
  x86_64). Only Linux and Windows x86_64 builds are published today; on macOS
  or arm Linux the extension skips the download and falls back to `typelisp` on
  `PATH` — set `typelisp.executablePath` to a working compiler there.
- Setting `typelisp.executablePath` disables auto-update and uses that binary.
- Run **TypeLisp: Update Stage0 Compiler** to force a refresh.

## Settings

- `typelisp.executablePath`: explicit executable used to launch the LSP server.
  When set, it overrides the auto-downloaded stage0 compiler. Leave unset to let
  the extension manage stage0 automatically.
- `typelisp.stage0.autoUpdate`: download and keep the stage0 compiler current
  from GitHub releases (default `true`). Ignored when `typelisp.executablePath`
  is set.
- `typelisp.stage0.repo`: GitHub `owner/name` to download stage0 from (default
  `JoNil-Botta/typelisp`).
- `typelisp.stage0.releaseTag`: release tag to track (default `stage0-latest`,
  the mutable release republished on every push to `main`).
- `typelisp.stdlibRoots`: extra roots passed to `typelisp lsp` as repeated
  `--stdlib-root <dir>` arguments, in order.
- `typelisp.enableLanguageServer`: set to `false` to keep syntax highlighting
  but skip starting the LSP client.

Hover, completion, document symbols, and other language features should only be
surfaced when the TypeLisp LSP server implements the corresponding methods.

## Local Development

Use Node 20 or newer. Install dependencies and build the compiled extension
entry:

```sh
npm install
npm run compile
```

Useful scripts:

```sh
npm run check
npm run lint
npm run package
npm run smoke
```

Open `tools/vs-code-extension/` in VS Code and run the `Run Extension` launch
configuration or press F5. In the Extension Development Host, open a `.tl` file;
the extension downloads a stage0 compiler automatically. To test against a local
build instead, set `typelisp.executablePath` to that binary (which disables the
download).

## Packaging

`npm run package` compiles the extension and writes a VSIX smoke artifact to
`dist/typelisp-0.0.1.vsix`. The `dist/` directory and generated `.vsix` files
are package artifacts and should not be committed.
