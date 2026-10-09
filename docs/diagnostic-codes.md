# Diagnostic code inventory

Published diagnostic codes are append-only. Never change the meaning of an
existing number or reuse a retired number. The executable registry lives in
`src/compiler_diagnostic.tl`; `src/explain_cli_core.tl` must provide a detailed
entry for every row. Its registry test in `src/cli_core_tests.tl` rejects
missing prose, while `src/compiler_diagnostic_tests.tl` rejects empty and
duplicate rows.

| Code | Category | Kind | Owner | Public construction site | Explain |
| --- | --- | --- | --- | --- | --- |
| E0100 | parse | parse error | parser | `parse-ast-canonical-diagnostic` for a message without a kind | detailed |
| E0200 | typecheck | unclassified typecheck error | typechecker | `tc-canonical-diagnostic` for a message without a kind | detailed |
| E0201 | typecheck | unbound name | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0202 | typecheck | arity mismatch | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0203 | typecheck | non-exhaustive match | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0204 | typecheck | unknown struct field | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0205 | typecheck | region escape | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0206 | typecheck | type mismatch | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0207 | typecheck | borrow violation | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0208 | typecheck | move violation | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0209 | typecheck | unsafe context required | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0210 | typecheck | lifetime mismatch | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0211 | typecheck | resource ownership violation | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0212 | typecheck | arena ownership violation | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0213 | typecheck | invalid pattern | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0214 | typecheck | SPMD restriction | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0215 | typecheck | invalid storage place | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0216 | typecheck | control-flow misuse | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0217 | typecheck | thread-safety violation | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0218 | typecheck | compile-time constraint | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0219 | typecheck | unsafe callable effect erasure | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0220 | typecheck | global written outside its module | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0221 | typecheck | opaque representation used outside its module family | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0101 | parse | unbalanced delimiter | reader | `token.SourceErrorKind` `DelimiterError` | detailed |
| E0102 | parse | malformed token | lexer, reader | `token.SourceErrorKind` `TokenError` | detailed |
| E0103 | parse | malformed form | parser | raise-site `CompilerParseKind` | detailed |
| E0104 | parse | invalid pattern syntax | parser | raise-site `CompilerParseKind` | detailed |

Rows are in registry order, which is append order. `E01..` codes are parse
codes and `E02..` codes are typecheck codes.

## Parse error families

Every public lexer, reader and parser error belongs to one family below. The
code follows the family stated where the error is raised, never the wording:
a parser raise site tags its message with a `CompilerParseKind`
(`parse-kind-message`), and a lexer or reader error carries a
`token.SourceErrorKind`. `parse-ast-canonical-diagnostic` keeps that code and
gives an error without one `E0100`. Recovery keeps every diagnostic's span and
source order; a lexer error is fatal, so it is the only diagnostic for its
file.

| Family | Examples | Code | Owner | Explain |
| --- | --- | --- | --- | --- |
| Unbalanced delimiter | `reader: unterminated list`, `reader: unexpected ')'`, `reader: mismatched delimiter`, `reader: unexpected end of input` | E0101 | reader | detailed |
| Malformed token | every `lexer:` error (unexpected character, malformed integer literal, unterminated string or character literal, unknown or unterminated escape); `reader:` dotted field access with an empty or numeric field | E0102 | lexer, reader | detailed |
| Malformed form | `parse: malformed <form>`, `<form> expects ...`, `<form> requires ...`, `... is missing ...`, `expected ':' in ...`, `expected type`, `expected declaration`, a part of the wrong syntactic kind, metadata before the items it must precede | E0103 | parser | detailed |
| Invalid pattern syntax | `parse: expected pattern`, slice-pattern `&` rest errors | E0104 | parser | detailed |
| Unknown name or keyword | `unknown <form> metadata`, `unknown type constructor`, `unknown extern ABI`, `unsupported <op> operator`, `CFunc mode must be ...`, `:spmd-callable` class keywords | E0100 | parser | detailed (E0100) |
| Duplicate metadata | `duplicate <form> <key> metadata`, `foreach domain bindings must use distinct names` | E0100 | parser | detailed (E0100) |
| Metadata or value constraint | `field :align metadata requires struct (:repr c) metadata`, `:align value must be a power of two ...`, `lanes must be greater than one`, `... cannot be used on functions with comptime parameters` | E0100 | parser | detailed (E0100) |
| Removed or deferred syntax | `... was removed; use ...`, `... is retired`, `no longer supported`, public SPMD source types, `packed repr is reserved`, source-level generics | E0100 | parser | detailed (E0100) |
| REPL input | `expected REPL input`, `trailing tokens after REPL input` | E0100 | parser | detailed (E0100) |
| Compiler-internal shapes | `malformed internal resolved type ...`, `malformed internal binary data` | E0100 | parser | detailed (E0100) |

A parser error handed to other code as text (`parse-ast-source`,
`parse-ast-expr`, `parse-ast-decl-maybe`) has no tag, so a syntax error in
macro output stays a typecheck diagnostic.

Parser and typechecker canonicalization are the current production sites for
stable public codes. Loader, package, macro, lowering, backend, linker,
formatter, lint, documentation, and test diagnostics still contain uncoded
public paths. Add category-specific codes at their canonical conversion points
before claiming those strings as stable API. Test-only uses of
`compiler-diagnostic-with-code` exercise transport/rendering and do not create
registry entries.

When adding a code:

1. Add its constructor and exactly one registry row in
   `src/compiler_diagnostic.tl`.
2. Assign it at the category's canonical diagnostic conversion point and pin
   representative real messages, including macro or cross-file spans where
   relevant. A typecheck code also gets a `CompilerTypecheckKind` variant, and
   every site that raises that error tags its message with it
   (`tc-kind-message`); a parse code gets a `CompilerParseKind` variant the
   same way (`parse-kind-message`). The code never depends on the wording.
3. Add complete `Description`, `Minimal failing example`, `Fix`, and `See also`
   sections in `src/explain_cli_core.tl`.
4. Add a public CLI or safety-corpus assertion that observes the code without
   changing JSON, LSP, or other machine-output schemas.

## Error results and generated code

Public source-facing compiler errors are `CompilerDiagnostic` values, or pass
through an adapter that keeps the path, span, category, code, labels, notes and
help. Internal parser and typechecker helpers may return `String` errors when
every caller attaches source context before the error leaves the phase.
Operational CLI, configuration and tool failures (argv validation, host
targets, process execution, linker discovery) may stay plain strings.
Structured stdlib and tool errors stay domain-specific and are adapted only at
a boundary with enough context. New source-facing package, load or tool errors
use `CompilerDiagnostic` rather than a new public `Err... String` variant;
migrate one public boundary at a time, with tests that prove its path and span
survive.

A diagnostic in generated or comptime code points at the nearest concrete
source span of the generated payload. The generated origin goes into notes,
not the message: `generated identity: <key>` when the identity is known, and
`generated declaration: <item> from <generator>`. Without a concrete span, the
same notes use the phase fallback span at line 1, column 1; there are no
virtual generated file names.
