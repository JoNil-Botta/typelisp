# TypeLisp VS Code Extension

First-party VS Code extension for the TypeLisp language (#922).

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
- The `TypeLisp: Restart Language Server` command.
- npm scripts for TypeScript compilation and VSIX packaging smoke.

## Settings

- `typelisp.executablePath`: executable used to launch the LSP server. Defaults
  to `typelisp` on `PATH`.
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
configuration or press F5. In the Extension Development Host, open a `.tl` file
and make sure `typelisp.executablePath` points at a working compiler binary if
`typelisp` is not on `PATH`.

## Packaging

`npm run package` compiles the extension and writes a VSIX smoke artifact to
`dist/typelisp-0.0.1.vsix`. The `dist/` directory and generated `.vsix` files
are package artifacts and should not be committed.
