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

Total inline Rust `#[test]` items under `src/`: 924.

| Rust source file | Rust tests | Behavior protected | Replacement path | Status |
| --- | ---: | --- | --- | --- |
| `src/typechecker.rs` | 308 | Type rules for scalars, strings, arrays, structs, enums, tuples, functions, lambdas, patterns, matches, builtins, regions, comptime/type-valued parameters, diagnostics, loops, and SPMD reduce. | #1042 migrates these into typechecker module self-tests, inline TypeLisp tests, and accepted/rejected selfhost corpus cases; #947 owns autodiscovery when inline tests are used. Statement/control-flow rules (`if`/`while` conditions, while-body unit rule, `set!`/`let`/`ann` type mismatches) are covered by `compiler-typecheck-statement-tests-ok?`, and operator/call rules (equality/comparison/integer-operator operand matching and call arity) by `compiler-typecheck-operator-tests-ok?`, and match/pattern rules (arm-type agreement, unknown-variant rejection, enum-payload/bool/wildcard accepts) by `compiler-typecheck-match-tests-ok?`, and string-builtin signature rules (`string-length`/`string-append`/`substring`/`string-eq` accepts + argument-type-mismatch rejection) by `compiler-typecheck-string-builtin-tests-ok?`, in `compiler_typecheck.tl`. | Partial |
| `src/backend/mod.rs` | 243 | Backend validation, target/mode policies, ABI lowering, phi/liveness handling, register/stack call shapes, scalar/float assembly, typed integer operations, runtime helper emission, Linux/Windows differences, aggregates, closures, arrays, strings, allocation, regions, and self-tail calls. | #1044 migrates backend-internal coverage; #845, #993, #1018, and #971 own public/runtime/native execution assertions that should not stay embedded in backend unit tests. | Partial |
| `src/lower.rs` | 168 | IR lowering for cross-module names, comptime specialization, function pointers, lambdas, closures, regions, tail calls, loops, vector/SPMD forms, globals, builtins, aggregate storage, enums, structs, arrays, strings, matches, casts, and numeric operations. | #1043 migrates structural lowerer coverage into `compiler-lower-self-test`, smoke drivers, inline tests, and manifest-backed no-Rust checks. | Partial |
| `src/parser.rs` | 76 | Declarations, imports, REPL items, let forms, comptime syntax, type literals, spans, diagnostic rendering, enum/struct syntax, patterns, operators, loops, SPMD reductions, and region syntax. | #1041 migrates parser coverage into `compiler_parse_core.tl` self-tests, inline tests, and selfhost parser corpus cases; #947 owns autodiscovery when inline tests are used. Top-level declaration parsing (value/function `define`, `extern`, `defenum`, `defstruct`, `import` accepts + malformed-form rejections) is covered by `compiler-parse-declaration-tests-ok?`, and `let`-binding forms (untyped/multi/legacy-parenthesized accepts + empty-binding rejection, complementing the existing let error tests) by `compiler-parse-let-tests-ok?`, in `compiler_parse_core.tl` (#1072). | Partial |
| `src/module.rs` | 27 | Import graph loading, relative/transitive/diamond/cyclic imports, stdlib root resolution, package imports, flat namespace behavior, and imported-file diagnostics. | #1041 migrates loader behavior into selfhost loader tests and corpus fixtures; package-facing behavior also shares #845 where it crosses public tooling. Diamond-import dedup (entry→A,B→C loads C once) and transitive-import loading (entry→A→B→C chain) are covered by `compiler-load-diamond-import-ok?` and `compiler-load-transitive-import-ok?` in `compiler_load.tl`, alongside the existing normalize/provenance/conflict/duplicate/seen/import-dedup-cycle/fallback-path self-tests (#1074). | Partial |
| `src/optimizer.rs` | 23 | Constant folding, overflow preservation, typed integer folding, casts, copy propagation, DCE, CSE, branch joins, loops, vector/mask conservatism, and fixed-point behavior. | #1043 migrates optimizer assertions into `compiler-optimize-self-test`, smoke drivers, and no-Rust structural checks. | Partial |
| `src/specialize.rs` | 21 | Comptime specialization reuse, deterministic generated names, stable keys, shadowing, runtime rejection, type-valued parameters, and substitution. | #1043 migrates specialization assertions into selfhost specialization tests and smoke coverage. | Partial |
| `src/host_action.rs` | 17 | Host plan parsing for build/run actions, targets, backend modes, stdlib roots, runtime args, netstrings, CRLF handling, duplicate directives, and malformed plans. | #845 and #1018 own public/selfhost build-run host-plan replacement; plan-parser behavior should move to selfhost tool tests instead of new Rust coverage. | Partial |
| `src/package.rs` | 14 | Package manifest parsing, dependency aliases, duplicate/missing fields, path validation, upward discovery, and root-relative paths. | #845 owns no-Rust package/public-tool coverage through `scripts/verify-public-tools.sh` and package fixtures. | Partial |
| `src/lexer.rs` | 9 | Basic tokens, type tokens, single/multi-line spans, char literals, escapes, named characters, and unknown named-character errors. | Covered by `tests/inline/lexer_rust_coverage.tl` (16 inline TypeLisp assertions, refs #1071). | Covered |
| `src/ir.rs` | 8 | Instruction effects, runtime helper effect classification, optimizer conservatism predicates, vector/mask display, tail masks, and tail-call pretty printing. | `compiler-ir-effect-self-test` now covers current selfhost instruction effects, known runtime helper conservatism, and effect predicates through `compiler_ir_types_smoke.tl`; #1043 still owns vector/mask/tail-call display once those IR shapes exist in selfhost. | Partial |
| `src/backend/regalloc.rs` | 5 | Register allocation eligibility, live-after-call exclusions, deterministic spills, vector/mask exclusions, and System V versus Windows clobber models. | `compiler-regalloc-self-test` now covers params/non-scalars/address-taken eligibility, live-after-call exclusions, deterministic spills in the selfhost register pool, and System V versus Windows clobber-list divergence; vector/mask exclusions remain with #1043 until those IR shapes exist in selfhost. | Partial |
| `src/ctfe.rs` | 2 | CTFE type literal evaluation and type-value comparison. | Covered by `compiler-ctfe-self-test` in `compiler_ctfe.tl` and the native `compiler_ctfe_smoke.tl` driver. | Covered |
| `src/native.rs` | 2 | Default executable naming by target and scratch source build/run cleanup. | #847/#971 cover native run paths; #850 and #1018 cover temp filesystem and selfhost build/run replacement where Rust host helpers remain. | Partial |
| `src/diagnostic.rs` | 1 | Simple rendered caret diagnostic format. | Covered by `compiler-diagnostic-render-source` and `compiler-diagnostic-source-render-ok?` in `selfhost/compiler_diagnostic.tl`, reached by `selfhost/compiler_parse_smoke.tl`; #837 still owns the broader structured diagnostic model, and #845 owns public diagnostic command output. | Covered |

## File Inventory

| Rust test file | Behavior protected | Replacement path | Status |
| --- | --- | --- | --- |
| `tests/backend_diagnostics.rs` | Backend rejection diagnostics preserve source locations for unsupported aggregate returns. | Covered by the manifest-backed `tests/diagnostics/backend/` corpus run by `scripts/verify-public-tools.sh`. | Covered |
| `tests/calc_compile.rs` | `tests/integration/calc.tl` compiles to assembly and keeps the tokenizer, parser, evaluator, and imported token model wired together. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/cli.rs` | Public CLI usage/errors and behavior for compile/check/build/run/fmt/doc/doc-test/debug/package-adjacent flows, LSP, REPL, and selfhost REPL. | `scripts/verify-public-tools.sh` drives the `tests/public-tools/` corpus (`run-corpus.py`) which covers public REPL, public LSP diagnostics/lifecycle, and selfhost REPL/LSP frame behavior across 44 fixture files. Remaining package-specific migration belongs to #1077, and selfhost public execution parity remains blocked by #787/#1018/#1019. | Partial |
| `tests/fmt_golden.rs` | Formatter golden output and idempotence through the public `typelisp fmt` command. | Covered by `tests/format_golden/*.tl`, matching `*.expected` files, and the manifest/idempotence checks in `scripts/verify-public-tools.sh`. | Covered |
| `tests/integration.rs` | Linux compile, assemble, link, and run coverage for `tests/integration/*.tl`, selfhost smoke drivers, deterministic assembly, explicit build, selfhost-generated assembly, and backend/runtime helper execution. | Covered by `scripts/verify-integration.sh`, `tests/integration/native-linux.manifest`, `scripts/verify-selfhost-native.sh`, `scripts/check-deterministic-asm.sh`, and the narrower public/stdlib/selfhost verification scripts. | Covered |
| `tests/lexer_compile.rs` | Legacy TypeLisp lexer witness compiles to assembly. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/maybe_result_compile.rs` | Monomorphic Maybe/Result witness compiles to assembly. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/nested_eval_compile.rs` | Nested pattern evaluator compiles to assembly. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/nullary_variant_call_compile.rs` | Nullary enum variant call-form witness compiles to assembly. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/package_build.rs` | Package manifest discovery, deterministic output paths, path dependencies, and package diagnostics. | Covered by `scripts/verify-public-tools.sh`: deterministic assembly output (`package-build`), upward manifest discovery (`package-discover-upward`), manifest parse errors (`package-parse-error`), path dependency import resolution (`package-build`), missing package alias (`package-missing-alias`), and missing dependency file diagnostics (`package-missing-dep-file`). | Covered |
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
