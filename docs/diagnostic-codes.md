# Diagnostic code inventory

Published diagnostic codes are append-only. Never change the meaning of an
existing number or reuse a retired number. The executable registry lives in
`src/compiler_diagnostic.tl`; `src/explain_cli_core.tl` must provide a detailed
entry for every row. Its registry test rejects missing prose, while
`src/compiler_diagnostic_tests.tl` rejects empty and duplicate rows.

| Code | Category | Kind | Owner | Public construction site | Explain |
| --- | --- | --- | --- | --- | --- |
| E0100 | parse | parse error | parser | `compiler_parse_core.tl` recovery/canonicalization | detailed |
| E0200 | typecheck | unclassified typecheck error | typechecker | `tc-canonical-diagnostic` fallback | detailed |
| E0201 | typecheck | unbound name | typechecker | `tc-canonical-diagnostic` classifier | detailed |
| E0202 | typecheck | arity mismatch | typechecker | `tc-canonical-diagnostic` classifier | detailed |
| E0203 | typecheck | non-exhaustive match | typechecker | `tc-canonical-diagnostic` classifier | detailed |
| E0204 | typecheck | unknown struct field | typechecker | `tc-canonical-diagnostic` classifier | detailed |
| E0205 | typecheck | region escape | typechecker | `tc-canonical-diagnostic` classifier | detailed |
| E0206 | typecheck | type mismatch | typechecker | `tc-canonical-diagnostic` classifier | detailed |
| E0207 | typecheck | borrow violation | typechecker | `tc-canonical-diagnostic` classifier | detailed |
| E0208 | typecheck | move violation | typechecker | `tc-canonical-diagnostic` classifier | detailed |
| E0209 | typecheck | unsafe context required | typechecker | `tc-canonical-diagnostic` classifier | detailed |
| E0210 | typecheck | lifetime mismatch | typechecker | `tc-canonical-diagnostic` classifier | detailed |
| E0211 | typecheck | resource ownership violation | typechecker | `tc-canonical-diagnostic` classifier | detailed |
| E0212 | typecheck | arena ownership violation | typechecker | `tc-canonical-diagnostic` classifier | detailed |
| E0213 | typecheck | invalid pattern | typechecker | `tc-canonical-diagnostic` classifier | detailed |
| E0214 | typecheck | SPMD restriction | typechecker | `tc-canonical-diagnostic` classifier | detailed |
| E0215 | typecheck | invalid storage place | typechecker | `tc-canonical-diagnostic` classifier | detailed |
| E0216 | typecheck | control-flow misuse | typechecker | `tc-canonical-diagnostic` classifier | detailed |
| E0217 | typecheck | thread-safety violation | typechecker | `tc-canonical-diagnostic` classifier | detailed |
| E0218 | typecheck | compile-time constraint | typechecker | `tc-canonical-diagnostic` classifier | detailed |

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
   relevant.
3. Add complete `Description`, `Minimal failing example`, `Fix`, and `See also`
   sections in `src/explain_cli_core.tl`.
4. Add a public CLI or safety-corpus assertion that observes the code without
   changing JSON, LSP, or other machine-output schemas.
