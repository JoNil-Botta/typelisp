# Rust Test Coverage Replacement Map

`tests/*.rs` audit date: 2026-05-24. Source baseline: `main` at `3c99210`.
`src/*.rs` inline-test audit date: 2026-05-25. Source baseline:
`origin/main` at `fce7c0c`.

This map tracks every Rust test harness file under `tests/*.rs`, plus inline
Rust unit tests under `src/*.rs`, and the no-Rust replacement path needed before
#793 and #795 can delete Cargo/Rust as a required test path. A replacement can
be an existing selfhost module self-test, a TypeLisp corpus fixture, a
verification script, or a focused follow-up issue.

Status meanings:

- Covered: the behavior already has a TypeLisp-owned fixture, self-test, or
  script runner that can become the primary assertion path.
- Partial: TypeLisp sources or scripts exist, but Rust still owns important
  assertions, manifests, platform glue, or expected-output checks.
- Gap: no no-Rust replacement exists yet; the linked issue owns the migration.

## Follow-Up Owners

- #845 replaces public CLI/package/doc/LSP/REPL/golden behavior currently
  embedded in Rust harnesses.
- #846 replaces Rust compile/symbol smoke tests with a no-Rust selfhost compile
  manifest.
- #847 replaced Rust native integration and platform runners with no-Rust
  manifests and host-aware scripts; #971 owns the Linux selfhost-generated
  native assembly slice now covered by `scripts/verify-selfhost-native.sh`.
- #947 owns repository-wide autodiscovery and CI execution for inline TypeLisp
  `(test ...)` items. It is separate from this content migration inventory.
- #1041 owns frontend parser, lexer, loader, and diagnostic inline Rust test
  migration.
- #1042 owns typechecker inline Rust test migration.
- #1043 owns lowering, optimizer, specialize, IR, and CTFE inline Rust test
  migration.
- #1044 owns backend, codegen, liveness, and regalloc inline Rust test
  migration.

## src/*.rs Inline Unit Test Inventory

Audit date: 2026-05-25. Source baseline: `origin/main` at `fce7c0c`.

Total inline Rust `#[test]` items under `src/`: 933.

| Rust source file | Rust tests | Behavior protected | Replacement path | Status |
| --- | ---: | --- | --- | --- |
| `src/typechecker.rs` | 308 | Type rules for scalars, strings, arrays, structs, enums, tuples, functions, lambdas, patterns, matches, builtins, regions, comptime/type-valued parameters, diagnostics, loops, and SPMD reduce. | #1042 migrates these into typechecker module self-tests, inline TypeLisp tests, and accepted/rejected selfhost corpus cases; #947 owns autodiscovery when inline tests are used. Statement/control-flow rules (`if`/`while` conditions, while-body unit rule, `set!`/`let`/`ann` type mismatches) are covered by `compiler-typecheck-statement-tests-ok?`, and operator/call rules (equality/comparison/integer-operator operand matching and call arity) by `compiler-typecheck-operator-tests-ok?`, and match/pattern rules (arm-type agreement, unknown-variant rejection, enum-payload/bool/wildcard accepts) by `compiler-typecheck-match-tests-ok?`, and string-builtin signature rules (`string-length`/`string-append`/`substring`/`string-eq` accepts + argument-type-mismatch rejection) by `compiler-typecheck-string-builtin-tests-ok?`, and argv-builtin signature rules (`arg-count`, `arg`, bad index type, bad arity, shadowing) by `compiler-typecheck-argv-builtin-tests-ok?`, and lambda rules (typed/nullary/inferred-return `(-> ...)` accepts + return-type-mismatch rejection, plus closure-capture typing — scalar, multi-scalar, `String`, and struct captures and aggregate-returning lambdas accept, #1542) by `compiler-typecheck-lambda-tests-ok?`, and cast rules (integer widen/narrow + int↔char accepts; f64-source and bool-source rejections requiring integer/char source and target) by `compiler-typecheck-cast-tests-ok?`, and `spmd-reduce` operator/type rules (`sum`→i32/i64/f64, `min`/`max`→i32/i64, `all`/`any`→bool accepts + unsupported operator/type rejections) by `compiler-typecheck-spmd-reduce-op-tests-ok?` (#1011), and array-builtin signature rules (`make-array` length, `array-ref` array/index types, `array-set!` value-type agreement accepts + non-integer-index / non-integer-length / value-mismatch rejections) by `compiler-typecheck-array-builtin-tests-ok?`, and `comptime` rules (a `(comptime ...)` form is typed by its inner expression and flows that type to the use site — `i64`/`bool`/`let`-`if`/nested-in-arithmetic accepts + runtime-variable-reference and comptime-result-type-mismatch rejections) by `compiler-typecheck-comptime-tests-ok?`, and IO-builtin signature rules (`read-file` String→String, `write-file` String/String→unit, `file-exists?` String→bool accepts + non-String-arg / wrong-arity / result-type-mismatch rejections) by `compiler-typecheck-io-builtin-tests-ok?`, and declaration-namespace / duplicate rules (duplicate function/value names, define↔function collision, duplicate struct and enum type names, duplicate externs, and cross-module wrong-argument-type calls) by `compiler-typecheck-namespace-tests-ok?` (#1537), in `compiler_typecheck.tl`. Two Rust namespace cases remain unmigrated because the selfhost symbol table does not yet detect them — enum variants colliding with functions/defines/struct constructors, and builtin shadowing — tracked by #1558. | Partial |
| `src/backend/mod.rs` | 247 | Backend validation, target/mode policies, ABI lowering, phi/liveness handling, register/stack call shapes, scalar/float assembly, typed integer operations, runtime helper emission, Linux/Windows differences, aggregates, closures, arrays, strings, allocation, regions, and self-tail calls. | #1044 migrates backend-internal coverage; #845, #993, #1018, and #971 own public/runtime/native execution assertions that should not stay embedded in backend unit tests. Backend validation/diagnostic reject cases (f64 `Mov` value, f64 binary op, and f64 unary op all rejected with their `backend:` diagnostic at the offending instruction's span) are covered by `compiler-backend-instr-diagnostics-ok?` via `compiler-backend-self-test` / `compiler_backend_smoke.tl`; regalloc decisions (eligibility, live-after-call, deterministic spills, SysV-vs-Win64 clobbers) by `compiler-regalloc-self-test` (#1085); boolean source codegen (`and`/`or` branch instead of eager byte ops, bool `=` emits `sete`, no TODO) by `compiler-backend-bool-control-flow-ok?`; source-level string runtime helper emission (`string->int`, `int->string`, `substring`, and `string-concat` direct calls, helper labels, no extern placeholders/TODO) by `compiler-backend-string-runtime-ok?`; `string-ref` source indexing emit-shape (literal string data, unsigned bounds check, `tl_oob_abort`, zero-extended byte load, no TODO) by `compiler-backend-string-ref-shape-ok?` through `compiler_backend_smoke.tl` (#1417); fixed-array set/ref source indexing emit-shape (constant bound compare, scaled element address, store/load, no TODO) by `compiler-backend-fixed-array-shape-ok?` through `compiler_backend_smoke.tl` (#1416); non-constant String/enum/struct/dynamic-array global initializer emit shapes (pointer-sized `.comm`, `__global_init_*` calls before `main`, and pointer stores back to globals) by `compiler-backend-aggregate-global-init-shape-ok?` through `compiler_backend_smoke.tl` (#1413); scalar wide-op/div/mod, narrow typed integer instruction selection, plus f64 SysV and Win64 calling-shape emit fragments by `compiler-backend-{scalar-wide-ops,scalar-div-mod,narrow-scalar-instr,f64-abi,win64-f64-abi}-ok?` through `compiler_backend_smoke.tl` (#1044/#1353/#1393/#1456); and Windows large-frame stack probing (`__chkstk` for frames >= 4096 bytes while Linux keeps plain `sub`) by `compiler-backend-target-windows-stack-probe-ok?` through `compiler_backend_smoke.tl` (#1270). Checked div/mod/shift trap emit-shapes continue in #1455. | Partial |
| `src/lower.rs` | 168 | IR lowering for cross-module names, comptime specialization, function pointers, lambdas, closures, regions, tail calls, loops, vector/SPMD forms, globals, builtins, aggregate storage, enums, structs, arrays, strings, matches, casts, and numeric operations. | #1043 migrates structural lowerer coverage into `compiler-lower-self-test`, smoke drivers, inline tests, and manifest-backed no-Rust checks. Comptime constant-folding of the scalar operators (`-`/`/`/`%`/`bit-and`/`bit-or`/`bit-xor`/`shl`/`shr`/`=` collapse to a single constant `mov` with no residual binop) is covered by `compiler-lower-comptime-op-fold-tests-ok?`, complementing the existing `+`/`<`/`*`/`let`/`if` comptime-fold cases. Scalar `foreach` lowering — `(foreach ([i : ty start end]) body)` to a half-open `[start,end)` reference loop (index init, `<` guard branch, `+ 1` increment, unit result) — is implemented in `lower-foreach` and covered by `compiler-lower-foreach-tests-ok?` (basic/array-body/zero-length/nested accepts + a guard-branch/binop shape check) (#1012). Scalar `spmd-reduce` lowering — desugared in `lower-spmd-reduce` to an accumulator `while` loop (`acc`/`end`/index bound once over `[start,end)`, empty range returns `init`) covering all reduction ops: `sum`/`all`/`any` fold via a binop (`+`/`and`/`or`, `value` once), and `min`/`max` via a single-eval select temp (`(let [v value] (set! acc (if (<cmp> v acc) v acc)))`) so `value` evaluates exactly once — is covered by `compiler-lower-spmd-reduce-tests-ok?` (i64/f64 sum + integer min/max + bool all/any accepts + shape check) (#1013, #1187). #1405 adds the non-SIMD audit below and migrates globals/externs/global-store, scalar casts, and typed numeric op shapes into `compiler-lower-self-test`; the row stays Partial only for the named follow-up blockers. | Partial |
| `src/parser.rs` | 76 | Declarations, imports, REPL items, let forms, comptime syntax, type literals, spans, diagnostic rendering, enum/struct syntax, patterns, operators, loops, SPMD reductions, and region syntax. | #1041 migrates parser coverage into `compiler_parse_core.tl` self-tests, inline tests, and selfhost parser corpus cases; #947 owns autodiscovery when inline tests are used. Top-level declaration parsing (value/function `define`, `extern`, `defenum`, `defstruct`, `import` accepts + malformed-form rejections) is covered by `compiler-parse-declaration-tests-ok?`, and `let`-binding forms (untyped/multi/legacy-parenthesized accepts + empty-binding rejection, complementing the existing let error tests) by `compiler-parse-let-tests-ok?`, and SPMD forms (`foreach`/`spmd-reduce` accepts including empty-range, non-`i64` index-type, and expression start/end bounds + malformed-foreach/foreach-binding/missing-colon/unknown-reduce-operator/malformed-spmd-reduce rejections) by `compiler-parse-spmd-tests-ok?`, and match/pattern forms (literal/wildcard/bool/binding/variant pattern accepts + malformed-match/malformed-arm/expected-pattern rejections) by `compiler-parse-pattern-tests-ok?`, and unary/binary operator forms (`not`/`neg`/`bit-not` unary plus arithmetic/comparison/bitwise/shift/logical binary accepts + parser-owned malformed-unary/malformed-binary rejections) by `compiler-parse-operator-tests-ok?`, and type-literal forms (`(type i64)`/`(type (Array i64))`/`(type (-> ...))` accepts + empty/two-type `type expects exactly one type` rejections) by `compiler-parse-type-literal-tests-ok?`, and region forms (`(with-arena <ident> body+)` basic/multi-expression/nested accepts + missing-binder / non-identifier-binder / empty-body rejections) by `compiler-parse-region-tests-ok?`, in `compiler_parse_core.tl` (#1072, #1073). Additional #1073 coverage added: enum/struct expressions (defenum empty rejection, defstruct mixed fields, empty struct rejection, struct-get, struct construction-as-call) via `compiler-parse-enum-struct-tests-ok?`; pattern string/char literals (string arms, nested string payload, char literal pattern, named char literal value) via `compiler-parse-pattern-string-char-tests-ok?`. REPL-item parsing (`parse-ast-repl-source`: declaration item, parenthesized-expression item, bare-expression item accepts + trailing-token and malformed-expression rejections) is covered by `compiler-parse-repl-tests-ok?` (#1072). Comptime function-parameter parsing (`[comptime n : i64]` and the type-valued `[comptime T : type]` parse as top-level function parameters marked comptime, via `ast-param-list-has-comptime?`, plus the comptime-lambda-parameter rejection `comptime parameters are only supported on top-level function definitions`) is covered by `compiler-parse-comptime-param-tests-ok?` (#1072). | Partial |
| `src/module.rs` | 27 | Import graph loading, relative/transitive/diamond/cyclic imports, stdlib root resolution, embedded stdlib fallback, package imports, flat namespace behavior, and imported-file diagnostics. | #1041 migrates loader behavior into selfhost loader tests and corpus fixtures; package-facing behavior also shares #845 where it crosses public tooling. Diamond-import dedup (entry→A,B→C loads C once) and transitive-import loading (entry→A→B→C chain) are covered by `compiler-load-diamond-import-ok?` and `compiler-load-transitive-import-ok?` in `compiler_load.tl`, alongside the existing normalize/provenance/conflict/duplicate/seen/import-dedup-cycle/fallback-path self-tests, and the imported-file diagnostic for an unreadable import (`cannot read import <path>`) by `compiler-load-missing-import-ok?`, plus imported-file diagnostic provenance — a parse error and a duplicate-`(module ...)` error inside an *imported* file both carry the imported file's path rather than the importer's — by `compiler-load-imported-parse-error-path-ok?` and `compiler-load-imported-duplicate-module-path-ok?`, plus `--stdlib-root` resolution — root fallback when the importer-relative path is absent, in-order searched-root selection (a missing leading root is skipped), and the cannot-read diagnostic naming the importer-relative candidate when no root resolves — by `compiler-load-stdlib-root-fallback-ok?`, `compiler-load-stdlib-searched-root-ok?`, and `compiler-load-stdlib-unresolved-ok?`, plus relative-resolution variants — importer-relative join, parent-directory (`..`) resolution end-to-end (join then normalize), and absolute-path preservation (Unix-rooted and Windows-drive imports ignore the importer dir) — by `compiler-load-relative-resolution-ok?` (#1074). Embedded stdlib fallback is a temporary Rust stage0 loader provider for #1507; it is guarded by Rust unit tests for virtual identity/dedup/diagnostics and by public CLI tests, while selfhost loader parity remains under #1041/#795 because the TypeLisp-built bundle still carries checked-in stdlib files instead of this Rust `include_str!` table. Package-import loading (#834) is covered by `compiler-load-pkg-manifest-ok?` (typelisp.pkg manifest parse — full and no-dependencies accepts plus the `name`/`version`/`entry` missing-required-field rejections), `compiler-load-pkg-resolve-ok?` (`pkg:<alias>/...` resolution to the dependency's on-disk path and a vendored path, plus unknown-alias / missing-`/`-after-alias / package-root-escape rejections), and `compiler-load-pkg-parent-dir-ok?` (the manifest-discovery directory walk-up that steps one parent at a time down to the cwd) — all dispatched from `compiler-load-self-test`; the Linux no-Rust selfhost compiler-driver path is covered by `scripts/verify-selfhost-native.sh` via `compiler-driver-pkg-import` (pkg import success, normalized relative-path dedup to the same dependency file, missing alias, missing dependency file, package-root escape, and package-import flat-namespace duplicate diagnostics). | Partial |
| `src/optimizer.rs` | 23 | Constant folding, overflow preservation, typed integer folding, casts, copy propagation, DCE, CSE, branch joins, loops, vector/mask conservatism, and fixed-point behavior. | #1043 migrates optimizer assertions into `compiler-optimize-self-test`, smoke drivers, and no-Rust structural checks. Current selfhost coverage includes constant/typed/cast folding, overflow/trap preservation, strength reduction, DCE including memory operand uses, CSE invalidation, block-local copy propagation including CSE-exposed copies and phi-input non-rewrite, bounds-check elimination, CFG simplification, opt-level policy, fixed-point behavior, source-span preservation through rewrite/drop cases, and CFG/dominance plus SSA/CFG verifier coverage through `compiler-optimize-ssa-self-test`. Vector/mask conservatism is covered by `compiler-optimize-vector-mask-self-test`: constant folding and bounds facts preserve/invalidate private vector/mask/tail-mask IR, DCE keeps used vector/mask values, scalar CSE does not rewrite duplicate `VectorBinOp` or `VectorReduce` instructions to `Mov`, vector reduction results clear stale scalar constants, and scalar copy propagation does not flow copies into vector/mask binops or mask reductions. | Covered |
| `src/specialize.rs` | 21 | Comptime specialization reuse, deterministic generated names, stable keys, shadowing, runtime rejection, type-valued parameters, and substitution. | #1043 migrates specialization assertions into selfhost specialization tests and smoke coverage. Type-valued parameters, runtime-type-use rejection, and template/type shadowing are covered by `compiler-specialize-{type-param,runtime-type-use-rejected,template-shadow,type-shadow,raw-pointer-type}` checks; deterministic generated names and stable specialization keys (exact mangling, idempotence, distinct-arg non-collision, multi-value ordering, negative-scalar encoding) by `compiler-specialize-name-key-ok?`, and specialization reuse (two identical `alloc (type i64)` requests collapse to a single shared `__tl_specialized_alloc_type_i64_none` decl via the specialization cache, not two) by `compiler-specialize-reuse-ok?`, and type substitution (`spec-substitute-type` replacing a mapped type variable with its bound type, recursing through pointer/dyn-array/function types, and leaving an unmapped variable unchanged) by `compiler-specialize-subst-ok?`, and comptime value-expression substitution (`spec-substitute-values-expr` replacing a variable bound to a comptime value with that value's literal, leaving unmapped variables and literals unchanged, and recursing through compound expressions) by `compiler-specialize-value-subst-ok?` — all wired through `compiler-specialize-self-test` / `compiler_specialize_smoke.tl`. | Covered |
| `src/host_action.rs` | 17 | Host plan parsing for build/run actions, targets, backend modes, stdlib roots, runtime args, netstrings, CRLF handling, duplicate directives, and malformed plans. | #845 and #1018 own public/selfhost build-run host-plan replacement; plan-parser behavior should move to selfhost tool tests instead of new Rust coverage. | Partial |
| `src/package.rs` | 14 | Package manifest parsing, dependency aliases, duplicate/missing fields, path validation, upward discovery, and root-relative paths. | #845 owns no-Rust package/public-tool coverage through `scripts/verify-public-tools.sh` and package fixtures. | Partial |
| `src/lexer.rs` | 9 | Basic tokens, type tokens, single/multi-line spans, char literals, escapes, named characters, and unknown named-character errors. | Covered by `tests/inline/lexer_rust_coverage.tl` (16 inline TypeLisp assertions, refs #1071). | Covered |
| `src/ir.rs` | 8 | Instruction effects, runtime helper effect classification, optimizer conservatism predicates, vector/mask display, tail masks, and tail-call pretty printing. | `compiler-ir-effect-self-test` now covers current selfhost instruction effects, known runtime helper conservatism, effect predicates, vector/mask type-name helpers, vector/mask reduce-op names, vector/mask primitive descriptions, tail-mask index/length/lane metadata, and direct tail-call target/argument/return-type rendering through `compiler_ir_types_smoke.tl` (#1406/#1411). | Covered |
| `src/backend/regalloc.rs` | 5 | Register allocation eligibility, live-after-call exclusions, deterministic spills, vector/mask exclusions, and System V versus Windows clobber models. | `compiler-regalloc-self-test` now covers params/non-scalars/address-taken eligibility, live-after-call exclusions, deterministic spills in the selfhost register pool, and System V versus Windows clobber-list divergence; vector/mask exclusions remain with #1043 until those IR shapes exist in selfhost. | Partial |
| `src/ctfe.rs` | 2 | CTFE type literal evaluation and type-value comparison. | Covered by `compiler-ctfe-self-test` in `compiler_ctfe.tl` and the native `compiler_ctfe_smoke.tl` driver. | Covered |
| `src/native.rs` | 2 | Default executable naming by target and scratch source build/run cleanup. | #847/#971 cover native run paths; #850 and #1018 cover temp filesystem and selfhost build/run replacement where Rust host helpers remain. | Partial |
| `src/diagnostic.rs` | 1 | Simple rendered caret diagnostic format. | Covered by `compiler-diagnostic-render-source` and `compiler-diagnostic-source-render-ok?` in `selfhost/compiler_diagnostic.tl`, reached by `selfhost/compiler_parse_smoke.tl`; #837 still owns the broader structured diagnostic model, and #845 owns public diagnostic command output. | Covered |
| `src/lsp.rs` | 0 | The `typelisp lsp` server: JSON-RPC framing (`Content-Length` headers, JSON parsing), open-document tracking (`textDocument/didOpen`/`didChange`/`didClose`), the initialize/capabilities handshake, and the publish-diagnostics loop. No inline `#[test]` items — behavior is witnessed by `tests/tl_lsp_frame_compile.rs`. | `selfhost/lsp_frame.tl` + #789 own the selfhost LSP framing/server port; #845 owns public protocol-behavior coverage. The public `typelisp lsp` still runs the Rust server (selfhost routing pending #789). | Partial |
| `src/repl.rs` | 0 | The `typelisp repl` input loop: multiline paren-balancing, session declaration/source persistence (top-level decls are remembered and type-checked before the session is mutated), and bare-expression evaluation by compiling a scratch program. No inline `#[test]` items — behavior is witnessed by `tests/tl_repl_compile.rs`. | `selfhost/repl.tl` + #1026 (selfhost REPL eval) / #1027 (route public `repl` through selfhost). The public `typelisp repl` still runs the Rust loop (selfhost routing pending #1026/#1027). | Partial |

#1354 adds backend aggregate-return storage and allocator runtime emit-shape
coverage through `compiler-backend-aggregate-storage-shape-ok?`,
`compiler-backend-alloc-runtime-shape-ok?`, and `compiler_backend_smoke.tl`.
#1413 adds non-constant String/enum/struct/dynamic-array global initializer
emit-shape coverage through `compiler-backend-aggregate-global-init-shape-ok?`.
#1416 adds fixed-array set/ref backend emit-shape coverage through
`compiler-backend-fixed-array-shape-ok?`. Tuple/closure emit-shapes remain split
to #1388.

### src/lower.rs Non-SIMD Audit (#1405)

This is the current mapping for the non-SIMD `src/lower.rs` Rust inline tests.
SIMD vector/mask lowering remains under #1014, and backend assembly/codegen
assertions remain under #1044.

- Basic function/body/control-flow lowering (`test_lower_simple_function`,
  `if`, `while`, `begin`, `let`, `set!`, params/no-params/void, nested calls,
  direct calls, spans, and unsupported/reference diagnostics) is covered by
  `compiler-lower-ok-summary?`, `compiler-lower-spans-ok?`, and
  `compiler-lower-error-ok?` through `compiler-lower-front-half-tests-ok?` and
  `compiler-lower-back-half-tests-ok?`.
- Cross-module names and comptime specialization (`test_lower_cross_module_*`,
  comptime value/type params, declaration specialization) are covered by
  `compiler-lower-module-symbols-ok?`, `compiler-lower-module-qualified-ok?`,
  `compiler-lower-module-specialize-ok?`, and the specialization self-tests
  listed for `src/specialize.rs`.
- Globals and externs (`test_lower_globals`, casted/global scalar initializers,
  float/bool/unit globals, extern declarations, and global `set!`) are covered
  by `compiler-lower-global-shape-ok?`.
- Runtime builtins and shadowing (`panic`/`error`, `print-string`/`print-str`,
  argv, string conversion/slicing/append/equality, stdio, IO/file-status
  helpers, cpuid/xgetbv, and user-defined shadowing cases) are covered by
  `compiler-lower-runtime-helper-tests-ok?`,
  `compiler-lower-string-runtime-ok?`, `compiler-lower-string-shadow-shape-ok?`,
  `compiler-lower-file-handle-status-shape-ok?`, and
  `compiler-lower-stdio-ok?`.
- Aggregate, enum, struct, array, string, and match source-level lowering is
  covered by `compiler-lower-match-phi-shape-ok?`,
  `compiler-lower-enum-match-shape-ok?`, `compiler-lower-result-try-shape-ok?`,
  `compiler-lower-array-access-shape-ok?`,
  `compiler-lower-make-array-shape-ok?`, `compiler-lower-region-shape-ok?`,
  `compiler-lower-repr-c-shape-ok?`, plus the aggregate/enum/string payload
  accepted sources in `compiler-lower-front-half-tests-ok?`.
- Typed numeric ops are covered by `compiler-lower-numeric-shape-ok?`, which
  checks bitwise operators, shifts, f64 arithmetic/comparison, and scalar cast
  IR shapes. Comptime numeric folding remains covered by
  `compiler-lower-comptime-op-fold-tests-ok?` and
  `compiler-lower-comptime-fold-ok?`.
- Direct self-tail-call rewriting and tail-context propagation through `let`,
  final `begin`, `ann`, scalar `match`, and return-type-preserving casts are
  covered by `compiler-lower-tail-call-shape-ok?`, including the negative
  operand-position self-call case.
- Scalar `foreach`, `spmd-reduce`, logical short-circuiting, raw-pointer
  operations, and pointer call-value lowering are covered by
  `compiler-lower-foreach-tests-ok?`,
  `compiler-lower-spmd-reduce-tests-ok?`,
  `compiler-lower-and-or-short-circuit-shape-ok?`,
  `compiler-lower-raw-pointer-ops-ok?`, and
  `compiler-lower-raw-pointer-call-value-shape-ok?`.

Named remaining blockers:

- Function-valued lowerer calls (function-parameter call, named function as a
  value, and local function values shadowing top-level functions) are covered by
  `compiler-lower-function-value-shape-ok?`.
- Noncapturing lambda lowering (returned function values, immediate indirect
  calls, and unit-returning calls) is covered by
  `compiler-lower-noncapturing-lambda-tests-ok?` (#1552).
- Capturing closures, closure heap descriptors/calls, and capture deep-copy
  details remain split to #1418.
- Tuple construction/ref emit-shape parity has focused follow-up #1414.
  Fixed-array set/ref backend emit-shape parity is covered by
  `compiler-backend-fixed-array-shape-ok?` (#1416). Broader backend-only
  assembly assertions stay under #1044.
- SIMD `foreach`/SPMD vector and mask lowering stays under #1014.

### 2026-05-26 Inline Additions

- #1056 adds inline Rust tests in `src/typechecker.rs`, `src/lower.rs`, and
  `src/backend/mod.rs` for the `file-open-status` / `file-close-status`
  stage0 bridge. The no-Rust replacement path is the paired
  `selfhost/compiler_typecheck.tl` IO-builtin self-test,
  `selfhost/compiler_lower.tl` file-handle status shape self-test, and the
  manifest-backed `stdlib/tests/io_file_handle.tl` fixture. #1287 adds the
  selfhost-owned backend runtime path for the open/close helpers, including
  runtime-plan detection, extern suppression, Linux handle-table/helper labels,
  and Windows unsupported stubs. #1325 adds the selfhost-owned backend runtime
  path for the streaming read-chunk helpers with the same table/stub parity.

### 2026-05-27 Inline Additions

- #1016 adds two inline Rust tests in `src/backend/mod.rs` for the staged
  `tl_windows_sdk_registry_install` runtime helper. The no-Rust replacement is
  the manifest-backed `stdlib/tests/windows_registry_api.tl` fixture through
  `scripts/verify-stdlib.sh`, including the Windows no-Rust stage0 path and the
  staged-symbol skip until stage0 republishes. Backend emit-shape parity remains
  with #1044/#1287 until `selfhost/compiler_backend.tl` owns this runtime helper.
- #1355 moves backend checked integer execution behavior into checked-in
  `tests/integration/*.tl` fixtures and `scripts/verify-integration.sh` manifest
  cases: the no-Rust native path now runs division/remainder traps, signed
  MIN / -1 traps, u16 division-by-zero, shift-count traps, and valid shift-bound
  cases with expected native exits and stderr diagnostics.

### 2026-05-28 Inline Additions

- #1449 adds seven inline Rust tests for dynamic-array `array-push!` support:
  parser recognition, typechecker unit/mismatch/dynamic-array-only rules,
  `spmd-reduce` side-effect rejection, lowerer reallocation/copy/fat-value
  update shape, and backend allocation/update emission shape. The no-Rust
  replacement path is the paired selfhost implementation in
  `selfhost/compiler_parse_core.tl`, `selfhost/compiler_typecheck.tl`, and
  `selfhost/compiler_lower.tl`; the concrete selfhost checks are
  `compiler-typecheck-array-builtin-tests-ok?` and
  `compiler-lower-array-push-shape-ok?`, with end-to-end dynamic-array native
  coverage in the compiler-driver fixture run by `tests/integration.rs` and
  the CI integration scripts.

### 2026-05-29 Inline Additions

- #1538 expands the selfhost-owned `src/typechecker.rs` match/pattern
  replacement in `compiler-typecheck-match-tests-ok?`: nullary variant call
  forms and shadowing, bare/nullary enum patterns, string/struct/nested payload
  binding, nested refutability, enum/scalar/string/bool exhaustiveness, literal
  type checks, wildcard reachability, Maybe/Result matches, and direct vs
  inline-compound recursive enum cases.
- #1507 adds embedded-stdlib Rust loader tests in `src/module.rs` for the
  temporary Rust stage0 fallback provider: manifest coverage for checked-in
  `stdlib/**/*.tl`, virtual canonical path round-tripping, final-fallback load,
  relative imports inside the virtual root, virtual identity deduplication, and
  missing-module diagnostics that report searched roots plus embedded
  availability. The no-Rust replacement path is the existing TypeLisp-owned
  stdlib tree carried by the stage1 bundle; selfhost loader root/package
  behavior remains covered by `compiler_load.tl` and #1041/#795 owns deleting
  the Rust `include_str!` provider.
- #1507 also adds public CLI Rust tests in `tests/cli.rs` and Linux integration
  coverage in `tests/integration.rs` proving no-root/no-env `stdlib/string.tl`
  check/compile/run behavior and missing embedded-stdlib diagnostics. The
  no-Rust replacement path is the release/no-Rust fetch path that installs the
  bundled stdlib beside the stage1 wrapper, plus the existing public-tool,
  inline-test, integration, and stdlib verification scripts once #949/#1200
  complete the release provenance flip.

## File Inventory

| Rust test file | Behavior protected | Replacement path | Status |
| --- | --- | --- | --- |
| `tests/backend_diagnostics.rs` | Backend rejection diagnostics preserve source locations for unsupported aggregate returns. | Covered by the manifest-backed `tests/diagnostics/backend/` corpus run by `scripts/verify-public-tools.sh`. | Covered |
| `tests/calc_compile.rs` | `tests/integration/calc.tl` compiles to assembly and keeps the tokenizer, parser, evaluator, and imported token model wired together. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/cli.rs` | Public CLI usage/errors and behavior for compile/check/build/run/fmt/doc/doc-test/debug/package-adjacent flows, embedded stdlib fallback, LSP, REPL, and selfhost REPL. | `scripts/verify-public-tools.sh` drives the `tests/public-tools/` corpus (`run-corpus.py`) which covers public REPL, public LSP diagnostics/lifecycle, selfhost REPL/LSP frame behavior across 44 fixture files, the Linux selfhost build/run tool execution path (#1018), direct selfhost-test-driver inline-harness execution accepting an opt-level flag and its explicit Windows-unsupported diagnostic (#1401, temporary Rust witness for the selfhost/test.tl + selfhost/build_run_core.tl no-Rust inline runner), and direct `selfhost/build.tl` package-build parity for manifest discovery, path dependencies, diagnostics, and option handling (#1339). `scripts/check-stage1-wrapper.sh` now covers top-level stage1 wrapper package-build routing for `--manifest-path`, upward discovery, and missing-manifest diagnostics (#1330). Embedded stdlib fallback CLI behavior is temporary Rust stage0 coverage for #1507; the no-Rust path is the bundled stdlib installed with the stage1 wrapper and the #949/#1200 release/capability gates. Broader selfhost public execution parity remains blocked by #787/#1019 plus the remaining #1018 Windows slice. | Partial |
| `tests/fmt_golden.rs` | Formatter golden output and idempotence through the public `typelisp fmt` command. | Covered by `tests/format_golden/*.tl`, matching `*.expected` files, and the manifest/idempotence checks in `scripts/verify-public-tools.sh`. | Covered |
| `tests/integration.rs` | Linux compile, assemble, link, and run coverage for `tests/integration/*.tl`, selfhost smoke drivers, deterministic assembly, explicit build, embedded stdlib fallback, selfhost-generated assembly, and backend/runtime helper execution. | Covered by `scripts/verify-integration.sh`, `tests/integration/native-linux.manifest`, `scripts/verify-selfhost-native.sh`, `scripts/check-deterministic-asm.sh`, and the narrower public/stdlib/selfhost verification scripts. Embedded stdlib fallback is temporary Rust stage0 coverage for #1507; the no-Rust equivalent is the bundled stdlib in the stage1 release/fetch path owned by #949/#1200. | Covered |
| `tests/lexer_compile.rs` | Legacy TypeLisp lexer witness compiles to assembly. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/maybe_result_compile.rs` | Monomorphic Maybe/Result witness compiles to assembly. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/nested_eval_compile.rs` | Nested pattern evaluator compiles to assembly. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/nullary_variant_call_compile.rs` | Nullary enum variant call-form witness compiles to assembly. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/package_build.rs` | Package manifest discovery, deterministic output paths, path dependencies, package diagnostics, and (#1516) per-target `(link …)` manifest parsing, bad link-section rejection, link-search-path resolution from the manifest root, and threading manifest link inputs through to the native linker for package builds. | Covered by `scripts/verify-public-tools.sh`: deterministic package output (`package-build`), upward manifest discovery (`package-discover-upward`), manifest parse errors (`package-parse-error`), path dependency import resolution (`package-build`), missing package alias (`package-missing-alias`), missing dependency file diagnostics (`package-missing-dep-file`), and direct selfhost bin/lib package-build parity checks. The #1516 native package link path (assemble + link with manifest `(link …)` inputs) is exercised end-to-end by the package native-build path; selfhost parity is tracked in `selfhost/build.tl` (#1339). | Partial |
| `tests/parser_compile.rs` | Legacy TypeLisp parser witness compiles to assembly. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/spec_examples.rs` | `SPEC.md` Lisp examples follow metadata and expected diagnostics. | Covered by the `SPEC.md` metadata parser and check/compile/run loop in `scripts/verify-public-tools.sh`. | Covered |
| `tests/sym_i64_env_compile.rs` | Selfhost `String -> i64` symbol table compiles to assembly. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/tl_ast_compile.rs` | Early selfhost Sexpr-to-AST parser and real compiler AST type model compile. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/tl_compiler_backend_compile.rs` | Selfhost backend, backend smoke/runtime fixture, driver, optimizer, build, and run modules compile and embed expected symbols/messages. | Compile/symbol assertions are covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; executable runtime coverage remains with #847. | Covered |
| `tests/tl_compiler_lower_compile.rs` | Selfhost IR types, lowerer, liveness, regalloc, and smoke drivers compile. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/tl_compiler_parse_compile.rs` | Selfhost compiler parser core and smoke driver compile and preserve parse diagnostics/smoke data. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/tl_compiler_symbols_compile.rs` | Selfhost symbol and registry modules compile and keep expected diagnostics/symbols. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/tl_compiler_typecheck_compile.rs` | Selfhost typecheck/check modules and smoke drivers compile. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/tl_doc_driver_compile.rs` | Selfhost documentation driver compiles with extractor and renderer imports. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; public behavior remains with #845. | Covered |
| `tests/tl_doc_extract_compile.rs` | Selfhost doc extractor and smoke policy fixtures compile. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/tl_doc_html_compile.rs` | Selfhost HTML doc renderer and smoke driver compile and preserve embedded renderer fixtures. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/tl_doc_render_compile.rs` | Selfhost Markdown renderer and golden smoke fixtures compile. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/tl_doc_test_compile.rs` | Selfhost doctest extractor and policy fixtures compile. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; public `doc --test` also runs through `selfhost/doc.tl`. | Covered |
| `tests/tl_emit_compile.rs` | Selfhost emitter demo compiles to assembly. | Compile/symbol assertions are covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; executable behavior remains with #847. | Covered |
| `tests/tl_eval_compile.rs` | Selfhost evaluator compiles to assembly. | Compile/symbol assertions are covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; executable behavior remains with #847. | Covered |
| `tests/tl_format_compile.rs` | Selfhost formatter core, CST/doc/rules, and driver modules compile. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; public golden behavior remains with #845. | Covered |
| `tests/tl_frontend_tools_compile.rs` | Selfhost frontend inspection CLI driver compiles. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; parse compatibility follow-up remains #843. | Covered |
| `tests/tl_lexer_compile.rs` | Selfhost TypeLisp lexer driver compiles to assembly. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/tl_lsp_frame_compile.rs` | Selfhost LSP framing driver compiles. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; protocol behavior remains with #845. | Covered |
| `tests/tl_parse_compile.rs` | Selfhost parser, parse core, and compile smoke driver compile. | Covered by `selfhost/compile_manifest.txt`, `scripts/verify-selfhost-compile-manifest.sh`, and corpus execution in `scripts/verify-selfhost.sh`. | Covered |
| `tests/tl_reader_compile.rs` | Selfhost reader driver compiles with lexer/token imports. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/tl_repl_compile.rs` | Selfhost REPL driver compiles. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; interactive behavior remains with #845. | Covered |
| `tests/tl_text_buf_compile.rs` | Selfhost deterministic text buffer utility and driver compile. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; stdlib buffer work remains #821. | Covered |
| `tests/windows_native.rs` | Windows target compile/link/run behavior, runtime helper cases, dependency staging, runtime args, stdout/stderr, and exit codes. | Covered by the Windows path in `scripts/verify-integration.sh`, `tests/integration/native-windows.manifest`, and the script's Windows backend/compiler-driver fixture checks; the host-aware Windows paths in `verify-stdlib.sh` and `verify-examples.sh` cover stdlib/examples. | Covered |

## Maintenance Rules

- Any new `tests/*.rs` file or new Rust test case must update this table in the
  same PR with either a no-Rust replacement path or a follow-up issue. This
  also applies to new inline Rust `#[test]` items under `src/`.
- Prefer adding TypeLisp fixtures under `selfhost/tests/`, `tests/integration/`,
  `tests/format_golden/`, or a dedicated corpus directory plus a manifest check.
- Prefer source-owned TypeLisp inline `(test ...)` items for module-local
  executable checks once #947 can autodiscover and run them in CI. Until then,
  migrated tests must be reachable from an existing smoke driver, corpus, or
  verification script.
- Rust tests can remain as temporary stage0 reference coverage only when this
  map states the deletion condition.
- When a no-Rust replacement lands, update the row status and close or retarget
  the linked follow-up issue.
