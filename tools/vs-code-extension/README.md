# TypeLisp VS Code extension

First-party VS Code extension for the TypeLisp language (#922).

## Non-TypeLisp code exception

Per the #922 decision, the editor-extension glue under `tools/vs-code-extension/`
is an **explicit, narrow exception** to the "new project code should be
TypeLisp" rule: VS Code cannot load extensions written in TypeLisp. The
exception covers only VS Code integration glue — language registration,
TextMate grammar packaging, LSP client wiring, commands, and packaging metadata.

Compiler, formatter, parser, diagnostics, and LSP **server** behavior stay in
TypeLisp/selfhost code and must not be reimplemented here. Language analysis
(diagnostics, hover, completion) comes from the TypeLisp LSP server
(`typelisp lsp`), tracked by the selfhost LSP work (#789); this extension is
only a client.

## What this provides today

This first slice is **purely declarative** — it has no compiled extension code
and no npm dependencies, so it works as soon as VS Code loads the folder:

- Registers `.tl` files as the `typelisp` language.
- Syntax highlighting (`syntaxes/typelisp.tmLanguage.json`) for line/doc
  comments (`;`, `;;`, `;:`, `;#`), strings and escapes, single/named character
  literals (`#a'`, `#('`, `#\space'`), integer and float numbers, special forms
  (`define`, `lambda`, `if`, `let`, `match`, `foreach`, `defenum`/`defstruct`,
  `extern`, `import`, `comptime`, `spmd-reduce`, …), `true`/`false`/`unit`,
  built-in type names, the `->` arrow, `&`/`&mut` reference operators, and the
  name introduced by a `(define …)`.
- `language-configuration.json` for comment toggling, bracket matching, and
  auto-closing pairs.
- Settings (`typelisp.executablePath`, `typelisp.stdlibRoots`,
  `typelisp.enableLanguageServer`) for the forthcoming LSP client.

## Not yet included (follow-up to #922)

- The **LSP client glue** (a small `vscode-languageclient` activation that
  launches `typelisp lsp` over stdio and wires diagnostics/hover/completion).
  That part needs a Node/TypeScript build (`npm install`, `tsc`) and a VS Code
  instance to verify, so it is a separate slice; the settings above are already
  in place for it.
- Packaging/lint CI (`vsce package`, eslint) — practical once the Node build
  step exists.

## Local development

Pure-declarative highlighting needs no build:

1. Copy or symlink this folder into your VS Code extensions dir
   (`~/.vscode/extensions/typelisp` or `%USERPROFILE%\.vscode\extensions\typelisp`),
   or open it with **Run Extension** (F5) from a VS Code window.
2. Open any `.tl` file; highlighting applies automatically.

## Packaging (future)

Once the LSP client and a Node build land, package with
[`vsce`](https://github.com/microsoft/vscode-vsce):

```sh
npm install -g @vscode/vsce
vsce package
```
