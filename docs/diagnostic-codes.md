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
| E0222 | typecheck | call may write a borrowed global | typechecker | raise-site `CompilerTypecheckKind` | detailed |
| E0101 | parse | unbalanced delimiter | reader | `token.SourceErrorKind` `DelimiterError` | detailed |
| E0102 | parse | malformed token | lexer, reader | `token.SourceErrorKind` `TokenError` | detailed |
| E0103 | parse | malformed form | parser | raise-site `CompilerParseKind` | detailed |
| E0104 | parse | invalid pattern syntax | parser | raise-site `CompilerParseKind` | detailed |
| E0301 | load | cannot read source module | loader | missing-source branches below | detailed |
| E0302 | load | cannot read included file | loader | `compiler-load-include-read-error` | detailed |
| E0303 | load | cannot resolve import or include | loader | import/include resolver and expected-identity conversion | detailed |
| E0304 | load | missing selected import item | loader | selected-item validation below | detailed |
| E0305 | load | ambiguous import binding | loader | alias and unqualified collision conversion | detailed |
| E0307 | load | duplicate module declaration | loader | module declaration validation below | detailed |
| E0501 | macro | macro namespace error | macro expander | `MacroNamespace` sites below | detailed |
| E0502 | macro | invalid macro use | macro expander | `MacroUse` sites below | detailed |
| E0503 | macro | invalid macro output | macro expander | `MacroOutput` sites below | detailed |
| E0504 | macro | macro expansion depth exceeded | macro expander | `MacroDepth` sites below | detailed |
| E0505 | comptime | explicit compile-time error | compile-time evaluator | `ComptimeAuthorError` sites below | detailed |
| E0506 | comptime | compile-time evaluation failed | compile-time evaluator | `ComptimeEvaluation` sites below | detailed |
| E0507 | comptime | compile-time evaluation limit exceeded | compile-time evaluator | `ComptimeFuel` sites below | detailed |

Rows are in registry order, which is append order. `E01..` codes are parse
codes, `E02..` codes are typecheck codes, `E03..` codes are loader codes, and
`E05..` codes belong to macro expansion and compile-time evaluation.

## Macro expansion and compile-time evaluation

Every `ctfe-diagnostic-at-expr` call supplies a `CompilerMacroKind` at its
raise/conversion site. Existing tagged errors retain their original code;
an author's `comptime-error` String is data and always receives E0505, even
when its text resembles an internal tag. No classification examines natural
language prefixes. Native callbacks preserve codes when converting diagnostic
values into the session's String slot, and the native status boundary selects
fuel exhaustion from the status value.

| Code | Public raise/conversion families |
| --- | --- |
| E0501 | `compiler-symbols-duplicate-macro-message`; qualified/source/hygiene macro lookup; `macro-call-not-macro-diag`, including missing generated declarations and unfinished imported macro namespaces |
| E0502 | identity-key and signature operand validation; type/module/clause/binding-clause strategies; variadic parameter capture and binding; macro call position and compatibility checks |
| E0503 | `macro-output-syntax-diag` for non-parser output failures; expression result validation; `macro-module-incompatible-output-diag`; `macro-expand-module-generated-decls` module count/order validation |
| E0504 | `macro-expand-produced-node`, `macro-expand-node-with-fire-decision`, `macro-expand-expr` depth guards |
| E0505 | `ctfe-eval-comptime-error-call` after its String argument succeeds; native `compiler-comptime-host-callback-diagnostic-from-value` |
| E0506 | CTFE literal, variable, call, unary/binary, cast, local mutation, aggregate/array/string indexing, syntax construction/quotation, reflection and unsupported expression failures; native request/result/status failures other than fuel exhaustion |
| E0507 | `compiler-ctfe-eval` and `ctfe-eval-dotted-var-source` fuel guards; native `macro-stdlib-tlci-native-cookie` fuel-exhausted status |

The existing E0218 compile-time value/constraint rules and E0202 arity rules
are unchanged. A genuine parse/typecheck/load error encountered while
expanding a macro retains its code and producing category through located,
rich and nested expansion-frame transports. Generated declaration parsing
uses the parser's tagged result before its legacy text-only adapter strips
the tag. Loader failures reached through generated imports retain loader
codes; ordinary load-once cycles remain valid. Missing ordinary expression
names remain E0201 when no macro position or signature establishes a macro
lookup.

Canonicalization changes code/category metadata only. Primary and secondary
paths/spans, help, generated-identity notes and declaration/invocation labels
remain owned by the escaped diagnostic across later compiler jobs. JSON and
LSP payload schemas are unchanged.

## Loader and import error families

`compiler-diagnostic-load` assigns the code and `load` category from a
`CompilerLoadKind` at these construction sites in `compiler_load.tl`. Resolver
helpers keep plain internal messages; their caller knows the cause when it
attaches the import span. Classification never examines message wording.
Forwarded parse/typecheck diagnostics do not enter this conversion and retain
their code, category, primary/secondary paths and spans, help and notes.

| Code | Public construction sites |
| --- | --- |
| E0301 | `compiler-load-surface-summary-load-with-pools`; `compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current`; `compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current-fallback-with-pools`; `compiler-load-package-file-with-paths-and-roots-expect-cache-current-fallback` |
| E0302 | `compiler-load-include-read-error` (all four include kinds) |
| E0303 | `compiler-load-expand-include-with-pools`; `compiler-load-package-expand-include`; resolver-error arms of `compiler-load-decls-with-module-and-roots-cfg-root-with-pools-at-special-head` and `compiler-load-package-decls-with-module-and-roots`; `compiler-load-check-expected-module`; `compiler-load-seen-expected-module-with-paths` |
| E0304 | `compiler-load-check-unqualified-imports`; selected-item arms of `compiler-load-decls-with-module-and-roots-cfg-root-with-pools-at-special-head` and `compiler-load-package-decls-with-module-and-roots` |
| E0305 | `compiler-load-import-alias-collision-result`; both import/import and import/local arms of `compiler-load-unqualified-import-collision-result` |
| E0307 | `compiler-load-decls-module-id-loop`; duplicate module-body arm of `compiler-load-decls-with-module-and-roots-cfg-root-with-pools-at-special-head` |

Missing-source diagnostics identify the resolved source path; selected and
ambiguous imports identify the importing form. A collision with a recorded
local declaration retains its secondary label. Repeated imports and ordinary
import cycles remain valid under load-once semantics. The macro-table cycle
failure belongs to macro expansion, rather than ordinary loader resolution.

Explicit expected-identity checks are internal loader-API resolution contracts
and use E0303. A source module declaration may override its inferred file
identity. There is no separate published E0306 code for that valid override.
Package-qualified includes with unknown dependency aliases also use E0303;
E0302 covers failure to read a successfully resolved include path.

Package manifest, lock/cache and dependency-artifact failures are separate
conversion boundaries, tracked by #8982. The loader codes do not classify
forwarded macro/CTFE failures. The remaining siblings retain the #7136 scope.

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
| Invalid pattern syntax | `parse: expected pattern`, slice-pattern `&` rest errors, `(or ...)` with fewer than two alternatives, malformed `(fields ...)` entries | E0104 | parser | detailed |
| Unknown name or keyword | `unknown <form> metadata`, `unknown type constructor`, `unknown extern ABI`, `unsupported <op> operator`, `CFunc mode must be ...`, `:spmd-callable` class keywords | E0100 | parser | detailed (E0100) |
| Duplicate metadata | `duplicate <form> <key> metadata`, `foreach domain bindings must use distinct names` | E0100 | parser | detailed (E0100) |
| Metadata or value constraint | `field :align metadata requires struct (:repr c) metadata`, `:align value must be a power of two ...`, `lanes must be greater than one`, `... cannot be used on functions with comptime parameters` | E0100 | parser | detailed (E0100) |
| Removed or deferred syntax | `... was removed; use ...`, `... is retired`, `no longer supported`, public SPMD source types, `packed repr is reserved`, source-level generics | E0100 | parser | detailed (E0100) |
| REPL input | `expected REPL input`, `trailing tokens after REPL input` | E0100 | parser | detailed (E0100) |
| Compiler-internal shapes | `malformed internal resolved type ...`, `malformed internal binary data` | E0100 | parser | detailed (E0100) |

A parser error handed to other code through legacy text adapters
(`parse-ast-source`, `parse-ast-expr`, `parse-ast-decl-maybe`) has no tag.
Generated declarations use the tagged parser result directly, preserving
syntax errors in macro output as parse diagnostics.

Parser, typechecker, loader and macro/CTFE canonicalization are production
sites for stable public codes. Package, lowering, backend, linker,
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
