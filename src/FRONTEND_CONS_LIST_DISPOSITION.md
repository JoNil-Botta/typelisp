# Frontend Cons-List Disposition Audit

Issue #3343 classifies the frontend list/env/set/chain families before any
broad conversion work under #2565. Line numbers are from `main` at `6aecfa83`.

Disposition values are the controlled vocabulary from #3343:
`convert-to-generated-vector`, `convert-to-bespoke-dense-builder`,
`keep-persistent-cons`, `redesign-scope-stack`, and
`not-a-cons-migration-target`.

Follow-up issues:

- #3427: generated-vector migration for hot ordered AST source sequences.
- #3428: scoped-stack research for persistent/shared-tail env chains.
- #3429: measured dense-storage evaluation for typechecker layout/spec lists.

## Summary

The parser `Result*List` families are wrappers around data lists and are not
migration targets themselves. The real AST sequence families in
`compiler_ast_types.tl` are ordered source-tree data and should move together
only after the generated vector substrate is ready. The typechecker environment
families are not vector rewrites: they encode persistent scope and marker-scan
semantics and need scoped-stack design first. The layout/spec lists are a
separate measured slice because they are ordered metadata lists, not AST or
scope data. Test-local families in `compiler_typecheck.tl` are source-literal
fixtures and should change only as part of the production family they mirror.

No broad conversion PR should start from #2565 until this table has landed.

## src/compiler_parse_core.tl

Parser result wrappers carry either a parsed AST list or an error. They are
classified explicitly so later work does not count them as the data structures
that need storage migration.

| Family | File:line | Constructors | Access/order/indexing | Hotness | Disposition | Blocker/follow-up |
| --- | --- | --- | --- | --- | --- | --- |
| `ResultAstTypeList` | `src/compiler_parse_core.tl:26` | `OkAstTypeList` / `ErrAstTypeList` | Wrapper for ordered `AstTypeList`; no list traversal of its own. | Parser hot path as error plumbing only. | `not-a-cons-migration-target` | Follows `AstTypeList` in #3427. |
| `ResultAstLifetimeList` | `src/compiler_parse_core.tl:30` | `OkAstLifetimeList` / `ErrAstLifetimeList` | Wrapper for `AstLifetimeList`; no independent storage. | Cold/small. | `not-a-cons-migration-target` | Follows `AstLifetimeList` policy. |
| `ResultAstParamList` | `src/compiler_parse_core.tl:38` | `OkAstParamList` / `ErrAstParamList` | Wrapper for ordered params. | Parser path. | `not-a-cons-migration-target` | Follows `AstParamList` in #3427. |
| `ResultAstMacroParamList` | `src/compiler_parse_core.tl:46` | `OkAstMacroParamList` / `ErrAstMacroParamList` | Wrapper for ordered macro params. | Parser path, smaller volume. | `not-a-cons-migration-target` | Follows `AstMacroParamList` in #3427. |
| `ResultAstFieldDefList` | `src/compiler_parse_core.tl:54` | `OkAstFieldDefList` / `ErrAstFieldDefList` | Wrapper for ordered struct fields. | Parser path. | `not-a-cons-migration-target` | Follows `AstFieldDefList` in #3427. |
| `ResultAstVariantDefList` | `src/compiler_parse_core.tl:127` | `OkAstVariantDefList` / `ErrAstVariantDefList` | Wrapper for ordered enum variants. | Parser path. | `not-a-cons-migration-target` | Follows `AstVariantDefList` in #3427. |
| `ResultAstDispatchVariantList` | `src/compiler_parse_core.tl:139` | `OkAstDispatchVariantList` / `ErrAstDispatchVariantList` | Wrapper for ordered dispatch variants. | Cold. | `not-a-cons-migration-target` | Follows `AstDispatchVariantList` in #3427. |
| `ResultAstPatternList` | `src/compiler_parse_core.tl:147` | `OkAstPatternList` / `ErrAstPatternList` | Wrapper for ordered pattern payloads. | Parser path. | `not-a-cons-migration-target` | Follows `AstPatternList` in #3427. |
| `ResultAstLetBindingList` | `src/compiler_parse_core.tl:155` | `OkAstLetBindingList` / `ErrAstLetBindingList` | Wrapper for ordered let bindings. | Parser path. | `not-a-cons-migration-target` | Follows `AstLetBindingList` in #3427. |
| `ResultAstResourceBindingList` | `src/compiler_parse_core.tl:163` | `OkAstResourceBindingList` / `ErrAstResourceBindingList` | Wrapper for ordered resource bindings. | Cold. | `not-a-cons-migration-target` | Follows `AstResourceBindingList` in #3427. |
| `ResultAstMatchArmList` | `src/compiler_parse_core.tl:175` | `OkAstMatchArmList` / `ErrAstMatchArmList` | Wrapper for ordered match arms. | Parser path. | `not-a-cons-migration-target` | Follows `AstMatchArmList` in #3427. |
| `ResultAstExprList` | `src/compiler_parse_core.tl:191` | `OkAstExprList` / `ErrAstExprList` | Wrapper for ordered expression lists. | Parser hot path. | `not-a-cons-migration-target` | Follows `AstExprList` in #3427. |
| `ResultAstExportItemList` | `src/compiler_parse_core.tl:207` | `OkAstExportItemList` / `ErrAstExportItemList` | Wrapper for ordered export items. | Cold. | `not-a-cons-migration-target` | Follows `AstExportItemList` in #3427. |
| `ResultAstDeclList` | `src/compiler_parse_core.tl:221` | `OkAstDeclList` / `ErrAstDeclList` | Wrapper for ordered declarations. | Parser hot path for full files. | `not-a-cons-migration-target` | Follows `AstDeclList` in #3427. |
| `ResultAstDeclListDiagnostic` | `src/compiler_parse_core.tl:246` | `OkAstDeclListDiagnostic` / `ErrAstDeclListDiagnostic` | Diagnostic wrapper for declaration lists. | Parser/load path. | `not-a-cons-migration-target` | Follows `AstDeclList` in #3427. |

## src/compiler_ast_types.tl

These are production AST data lists. Families marked for generated vectors
should migrate only through #3427 so parser/builders, symbol/typecheck/lower
walkers, and any path-alignment logic change together.

| Family | File:line | Constructors | Access/order/indexing | Hotness | Disposition | Blocker/follow-up |
| --- | --- | --- | --- | --- | --- | --- |
| `AstTypeList` | `src/compiler_ast_types.tl:247` | `AstTypeNil` / `AstTypeCons` | Ordered type operands; hashing/equality and repeated traversal. | Hot in type and function signatures. | `convert-to-generated-vector` | Blocked by #3193/#3206; #3427. |
| `AstLifetimeList` | `src/compiler_ast_types.tl:251` | `AstLifetimeNil` / `AstLifetimeCons` | Ordered lifetime args; tiny and often pattern-matched recursively. | Cold/small. | `keep-persistent-cons` | No conversion issue unless measurements show this matters. |
| `AstParamList` | `src/compiler_ast_types.tl:266` | `AstParamNil` / `AstParamCons` | Ordered params; length/traversal during bind/check/lower. | Hot in function-heavy files. | `convert-to-generated-vector` | #3427. |
| `AstMacroParamList` | `src/compiler_ast_types.tl:273` | `AstMacroParamNil` / `AstMacroParamCons` | Ordered macro params; traversal for arity/type checks. | Moderate. | `convert-to-generated-vector` | #3427. |
| `AstFieldDefList` | `src/compiler_ast_types.tl:285` | `AstFieldDefNil` / `AstFieldDefCons` | Ordered fields; layout offset/index scans. | Moderate/hot for aggregate-heavy code. | `convert-to-generated-vector` | #3427. |
| `AstExternLinkInputList` | `src/compiler_ast_types.tl:307` | `AstExternLinkInputNil` / `AstExternLinkInputCons` | Ordered linker metadata; append/traverse only. | Cold. | `keep-persistent-cons` | No follow-up. |
| `AstVariantPayloadCleanupList` | `src/compiler_ast_types.tl:331` | `AstVariantPayloadCleanupNil` / `AstVariantPayloadCleanupCons` | Lockstep with variant payload type lists. | Cold/small but alignment-sensitive. | `convert-to-generated-vector` | #3427; migrate with `AstTypeList`. |
| `AstVariantDefList` | `src/compiler_ast_types.tl:340` | `AstVariantDefNil` / `AstVariantDefCons` | Ordered variants; index/lookup/layout traversals. | Moderate. | `convert-to-generated-vector` | #3427. |
| `AstPatternList` | `src/compiler_ast_types.tl:352` | `AstPatternNil` / `AstPatternCons` | Ordered tuple/variant pattern payloads. | Hot in match-heavy code. | `convert-to-generated-vector` | #3427. |
| `AstLetBindingList` | `src/compiler_ast_types.tl:359` | `AstLetBindingNil` / `AstLetBindingCons` | Ordered sequential bindings; bind/check/lower in order. | Hot. | `convert-to-generated-vector` | #3427. |
| `AstResourceBindingList` | `src/compiler_ast_types.tl:366` | `AstResourceBindingNil` / `AstResourceBindingCons` | Ordered resource cleanup bindings. | Cold/moderate. | `convert-to-generated-vector` | #3427. |
| `AstMatchArmList` | `src/compiler_ast_types.tl:373` | `AstMatchArmNil` / `AstMatchArmCons` | Ordered match arms; first-match semantics. | Hot in match-heavy code. | `convert-to-generated-vector` | #3427. |
| `AstExprList` | `src/compiler_ast_types.tl:1518` | `AstExprNil` / `AstExprCons` | Ordered call/body/tuple/array exprs; frequent traversal and count. | Very hot. | `convert-to-generated-vector` | #3427. |
| `AstExprClauseList` | `src/compiler_ast_types.tl:1526` | `AstExprClauseNil` / `AstExprClauseCons` | Ordered macro clause pairs. | Moderate in macro-heavy code. | `convert-to-generated-vector` | #3427. |
| `AstExportItemList` | `src/compiler_ast_types.tl:1560` | `AstExportItemNil` / `AstExportItemCons` | Ordered exports; symbol/import scans. | Cold. | `convert-to-generated-vector` | #3427, but low priority. |
| `AstDispatchVariantList` | `src/compiler_ast_types.tl:1572` | `AstDispatchVariantNil` / `AstDispatchVariantCons` | Ordered dispatch variants. | Cold. | `keep-persistent-cons` | Revisit only if dispatch metadata grows. |
| `AstDeclList` | `src/compiler_ast_types.tl:1604` | `AstDeclNil` / `AstDeclCons` | Ordered declarations; prefix cache, symbol, typecheck, lower passes. | Very hot. | `convert-to-generated-vector` | #3427; migrate with `AstDeclPathList`. |
| `AstDeclPathList` | `src/compiler_ast_types.tl:1608` | `AstDeclPathNil` / `AstDeclPathCons` | Parallel ordered paths for `AstDeclList`; lockstep traversal. | Hot wherever loaded programs are checked/lowered. | `convert-to-generated-vector` | #3427; must migrate with `AstDeclList`. |
| `AstDeclModuleList` | `src/compiler_ast_types.tl:1612` | `AstDeclModuleNil` / `AstDeclModuleCons` | Ordered module markers from loaded programs. | Moderate. | `convert-to-generated-vector` | #3427. |

## src/compiler_typecheck_core.tl

Typechecker chains split into three groups: persistent env stacks, ordered
layout/spec metadata, and wrappers around other data.

| Family | File:line | Constructors | Access/order/indexing | Hotness | Disposition | Blocker/follow-up |
| --- | --- | --- | --- | --- | --- | --- |
| `TcTypeEnv` | `src/compiler_typecheck_core.tl:34` | `TcTypeNil` / `TcTypeBind` / `TcTypeCache` | Persistent scope chain plus cache nodes and marker scans. | Very hot. | `redesign-scope-stack` | #3428; not a vector rewrite. |
| `ResultTcTypeList` | `src/compiler_typecheck_core.tl:66` | `OkTcTypeList` / `ErrTcTypeList` | Wrapper for `AstTypeList`. | Error plumbing. | `not-a-cons-migration-target` | Follows AST/type-list owner. |
| `ResultTcExprList` | `src/compiler_typecheck_core.tl:70` | `OkTcExprList` / `ErrTcExprList` | Wrapper for `AstExprList`. | Error plumbing. | `not-a-cons-migration-target` | Follows `AstExprList` in #3427. |
| `TcStringList` | `src/compiler_typecheck_core.tl:128` | `TcStringNil` / `TcStringCons` | Small stack/set/path lists for bound names, cycle chains, and owner/lifetime sets. | Frequent but usually tiny. | `keep-persistent-cons` | Specific hot call sites can be split later if measured. |
| `CompilerTcMacroProfileEntries` | `src/compiler_typecheck_core.tl:139` | `CompilerTcMacroProfileNil` / `CompilerTcMacroProfileCons` | Compile-profile-only report list. | Instrumentation only. | `not-a-cons-migration-target` | No follow-up. |
| `ResultTcStringList` | `src/compiler_typecheck_core.tl:148` | `OkTcStringList` / `ErrTcStringList` | Wrapper for `TcStringList`. | Error plumbing. | `not-a-cons-migration-target` | Follows `TcStringList` policy. |
| `ResultTcLifetimeList` | `src/compiler_typecheck_core.tl:152` | `OkTcLifetimeList` / `ErrTcLifetimeList` | Wrapper for `AstLifetimeList`. | Error plumbing. | `not-a-cons-migration-target` | Follows `AstLifetimeList` policy. |
| `TcLifetimeSubst` | `src/compiler_typecheck_core.tl:156` | `TcLifetimeSubstNil` / `TcLifetimeSubstCons` | Small substitution chain with shadow/conflict checks. | Moderate, but tiny. | `keep-persistent-cons` | Reconsider in #3428 if stack design needs it. |
| `ResultTcLifetimeSubst` | `src/compiler_typecheck_core.tl:160` | `OkTcLifetimeSubst` / `ErrTcLifetimeSubst` | Wrapper for `TcLifetimeSubst`. | Error plumbing. | `not-a-cons-migration-target` | Follows `TcLifetimeSubst`. |
| `TcMaybeTypeEnv` | `src/compiler_typecheck_core.tl:164` | `TcNoTypeEnv` / `TcSomeTypeEnv` | Option wrapper for an env value. | Cache lookup result. | `not-a-cons-migration-target` | Follows `TcTypeEnv` redesign. |
| `TcModuleLocalEnvCache` | `src/compiler_typecheck_core.tl:168` | `TcModuleLocalEnvNil` / `TcModuleLocalEnvCons` | Small cache chain keyed by module, values are `TcTypeEnv`. | Moderate in multi-module programs. | `redesign-scope-stack` | #3428; follows env design. |
| `ResultTcModuleLocalEnv` | `src/compiler_typecheck_core.tl:172` | `OkTcModuleLocalEnv` / `ErrTcModuleLocalEnv` | Wrapper for env cache result. | Error plumbing. | `not-a-cons-migration-target` | Follows `TcModuleLocalEnvCache`. |
| `ResultTcEnv` | `src/compiler_typecheck_core.tl:176` | `OkTcEnv` / `ErrTcEnv` | Wrapper for `TcTypeEnv`. | Error plumbing. | `not-a-cons-migration-target` | Follows `TcTypeEnv` redesign. |
| `TcSpmdEnv` | `src/compiler_typecheck_core.tl:200` | `TcSpmdEnvNil` / `TcSpmdEnvBind` | Persistent SPMD scope stack with pop/merge/mark-outer operations. | Hot in SPMD code. | `redesign-scope-stack` | #3428. |
| `TcSpmdExprListInfo` | `src/compiler_typecheck_core.tl:228` | `TcSpmdExprListInfo` | Summary for checking an expression list; not a list storage family. | SPMD expression checking. | `not-a-cons-migration-target` | No follow-up. |
| `TcReprCFieldLayoutList` | `src/compiler_typecheck_core.tl:274` | `TcReprCFieldLayoutNil` / `TcReprCFieldLayoutCons` | Ordered field layout metadata. | Layout/C ABI paths. | `convert-to-bespoke-dense-builder` | #3429; measure before landing. |
| `TcInlineFieldLayoutList` | `src/compiler_typecheck_core.tl:288` | `TcInlineFieldLayoutNil` / `TcInlineFieldLayoutCons` | Ordered inline field metadata; offset scans. | Layout/typecheck/lower paths. | `convert-to-bespoke-dense-builder` | #3429. |
| `TcInlinePayloadLayoutList` | `src/compiler_typecheck_core.tl:295` | `TcInlinePayloadLayoutNil` / `TcInlinePayloadLayoutCons` | Ordered enum payload metadata. | Layout/typecheck/lower paths. | `convert-to-bespoke-dense-builder` | #3429. |
| `TcInlineVariantLayoutList` | `src/compiler_typecheck_core.tl:304` | `TcInlineVariantLayoutNil` / `TcInlineVariantLayoutCons` | Ordered variant layout metadata. | Layout/typecheck/lower paths. | `convert-to-bespoke-dense-builder` | #3429. |
| `TcStdlibFieldSpecList` | `src/compiler_typecheck_core.tl:3115` | `TcStdlibFieldSpecNil` / `TcStdlibFieldSpecCons` | Tiny expected-field spec table. | Cold. | `keep-persistent-cons` | #3429 may confirm no conversion. |
| `TcStdlibVariantSpecList` | `src/compiler_typecheck_core.tl:3119` | `TcStdlibVariantSpecNil` / `TcStdlibVariantSpecCons` | Tiny expected-variant spec table. | Cold. | `keep-persistent-cons` | #3429 may confirm no conversion. |
| `TcMovedSet` | `src/compiler_typecheck_core.tl:25321` | `defstruct` over `StringI64Map` | Dense hash-map-backed move/borrow set, not a cons enum. | Hot move/borrow checking. | `not-a-cons-migration-target` | Already migrated away from cons shape. |
| `ResultMacroExprList` | `src/compiler_typecheck_core.tl:29837` | `OkMacroExprList` / `ErrMacroExprList` | Wrapper for `AstExprList`. | Macro expansion path. | `not-a-cons-migration-target` | Follows `AstExprList` in #3427. |
| `ResultMacroClauseList` | `src/compiler_typecheck_core.tl:29861` | `OkMacroClauseList` / `ErrMacroClauseList` | Wrapper for `AstExprClauseList`. | Macro expansion path. | `not-a-cons-migration-target` | Follows `AstExprClauseList` in #3427. |
| `ResultMacroDecls` | `src/compiler_typecheck_core.tl:29869` | `OkMacroDecls` / `ErrMacroDecls` | Wrapper for generated `AstDeclList`. | Macro expansion path. | `not-a-cons-migration-target` | Follows `AstDeclList` in #3427. |
| `ResultMacroDeclExpansion` | `src/compiler_typecheck_core.tl:29873` | `OkMacroDeclExpansion` / `ErrMacroDeclExpansion` | Wrapper for decl/path lists. | Macro expansion path. | `not-a-cons-migration-target` | Follows `AstDeclList`/`AstDeclPathList` in #3427. |
| `ResultMacroDeclsWithPaths` | `src/compiler_typecheck_core.tl:29877` | `OkMacroDeclsWithPaths` / `ErrMacroDeclsWithPaths` | Wrapper for decl/path lists. | Macro expansion path. | `not-a-cons-migration-target` | Follows `AstDeclList`/`AstDeclPathList` in #3427. |
| `ResultMacroParsedDecls` | `src/compiler_typecheck_core.tl:29897` | `OkMacroParsedDecls` / `ErrMacroParsedDecls` | Wrapper for parsed generated decls. | Macro expansion path. | `not-a-cons-migration-target` | Follows `AstDeclList` in #3427. |
| `MacroMaybeDeclList` | `src/compiler_typecheck_core.tl:29905` | `MacroNoDeclList` / `MacroSomeDeclList` | Option wrapper for an `AstDeclList`. | Macro module handling. | `not-a-cons-migration-target` | Follows `AstDeclList` in #3427. |
| `MacroHygieneEnv` | `src/compiler_typecheck_core.tl:29909` | `MacroHygieneNil` / `MacroHygieneBind` | Persistent rename environment with nested shared tails. | Macro expansion path. | `redesign-scope-stack` | #3428. |
| `MacroHygienePatternList` | `src/compiler_typecheck_core.tl:29928` | `MacroHygienePatternList` | Product wrapper for `AstPatternList` plus hygiene env. | Macro expansion path. | `not-a-cons-migration-target` | Follows `AstPatternList`/`MacroHygieneEnv`. |

## src/compiler_typecheck.tl

This file is a smoke-test module. Its apparent list/env families are mostly
source strings used to validate layout, typechecking, clone behavior, and
inline aggregate recursion. They are not production storage families.

| Family | File:line | Constructors | Access/order/indexing | Hotness | Disposition | Blocker/follow-up |
| --- | --- | --- | --- | --- | --- | --- |
| `StringList` fixture | `src/compiler_typecheck.tl:613` | `SNil` / `SCons` | Source-literal clone fixture. | Test only. | `not-a-cons-migration-target` | Keep until clone fixture changes. |
| `ListI64` fixtures | `src/compiler_typecheck.tl:1026`, `1724`, `1893` | `ListNil` / `ListCons` | Source-literal recursive-list/layout fixtures. | Test only. | `not-a-cons-migration-target` | Keep; update only with fixture intent. |
| `SymI64Env` fixture | `src/compiler_typecheck.tl:1903` | `SymI64Nil` / `SymI64Bind` | Source-literal env layout fixture. | Test only. | `not-a-cons-migration-target` | Production `SymI64Env` lives elsewhere. |
| `InlineHelperRootList` fixture | `src/compiler_typecheck.tl:1908` | `InlineHelperRootNil` / `InlineHelperRootCons` | Source-literal helper layout fixture. | Test only. | `not-a-cons-migration-target` | Keep as recursive-list coverage. |
| `CompilerPkgDepList` fixture | `src/compiler_typecheck.tl:1914` | `CompilerPkgDepNil` / `CompilerPkgDepCons` | Source-literal package-dep list layout fixture. | Test only. | `not-a-cons-migration-target` | Keep as recursive-list coverage. |
| `AstTypeList` fixtures | `src/compiler_typecheck.tl:1945`, `1987` | `AstTypeNil` / `AstTypeCons` | Source-literal mirrors for inline layout tests. | Test only. | `not-a-cons-migration-target` | Production family handled in #3427. |
| `CtfeEnv` fixture | `src/compiler_typecheck.tl:1966` | `CtfeEnvNil` / `CtfeEnvCons` | Source-literal CTFE metadata layout fixture. | Test only. | `not-a-cons-migration-target` | Production CTFE family is outside #2565. |
| `AstPatternList` fixture | `src/compiler_typecheck.tl:1993` | `AstPatternNil` / `AstPatternCons` | Source-literal AST layout fixture. | Test only. | `not-a-cons-migration-target` | Production family handled in #3427. |
| `AstExprList` fixture | `src/compiler_typecheck.tl:2001` | `AstExprNil` / `AstExprCons` | Source-literal AST layout fixture. | Test only. | `not-a-cons-migration-target` | Production family handled in #3427. |
| `FormatCstList` fixture | `src/compiler_typecheck.tl:2027` | `FmtCstNil` / `FmtCstCons` | Source-literal formatter layout fixture. | Test only. | `not-a-cons-migration-target` | Production formatter family is outside #2565. |

## Conversion Rules

- Do not convert parser result wrappers independently; they change only when
  their payload family changes.
- Do not vectorize env chains mechanically. `TcTypeEnv`, `TcSpmdEnv`, and
  `MacroHygieneEnv` need a scoped-stack design with explicit save/restore marks
  and marker-scan semantics (#3428).
- Treat `AstDeclList` and `AstDeclPathList` as a paired migration; every caller
  that assumes lockstep traversal must update in one slice.
- Measure before landing any conversion that claims speed or memory wins. The
  minimum evidence is before/after selfhost check/compile behavior plus focused
  parser/typecheck/layout coverage for the family being changed.
