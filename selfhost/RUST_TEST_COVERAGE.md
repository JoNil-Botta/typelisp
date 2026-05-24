# Rust Test Coverage Replacement Map

Audit date: 2026-05-24. Source baseline: `main` at `3c99210`.

This map tracks every Rust test harness file under `tests/*.rs` and the
no-Rust replacement path needed before #793 and #795 can delete Cargo/Rust as a
required test path. A replacement can be an existing selfhost module self-test,
a TypeLisp corpus fixture, a verification script, or a focused follow-up issue.

Status meanings:

- Covered: the behavior already has a TypeLisp-owned fixture, self-test, or
  script runner that can become the primary assertion path.
- Partial: TypeLisp sources or scripts exist, but Rust still owns important
  assertions, manifests, platform glue, or expected-output checks.
- Gap: no no-Rust replacement exists yet; the linked issue owns the migration.

## Follow-Up Owners

- #845 replaces public CLI/package/doc/LSP/REPL/golden behavior currently
  embedded in Rust harnesses.
- #846 added `selfhost/COMPILE_MANIFEST.txt` and
  `scripts/verify-selfhost-compile-manifest.sh` as the no-Rust replacement for
  Rust compile/symbol smoke tests. The Rust compile harnesses are temporary
  reference tests until #795 deletes Cargo/Rust as a required path.
- #847 replaces Rust native integration and platform runners with no-Rust
  manifests and host-aware scripts.

## File Inventory

| Rust test file | Behavior protected | Replacement path | Status |
| --- | --- | --- | --- |
| `tests/backend_diagnostics.rs` | Backend rejection diagnostics preserve source locations for unsupported aggregate returns. | Move into a public diagnostic corpus or shell CLI check owned by #845. | Gap |
| `tests/calc_compile.rs` | `tests/integration/calc.tl` compiles to assembly and keeps the tokenizer, parser, evaluator, and imported token model wired together. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; delete Rust harness at #795 cutover. | Covered |
| `tests/cli.rs` | Public CLI usage/errors and behavior for compile/check/build/run/fmt/doc/doc-test/debug/package-adjacent flows, LSP, REPL, and selfhost REPL. | Existing selfhost drivers plus scripts are partial coverage; public tool harness owned by #845. | Partial |
| `tests/fmt_golden.rs` | Formatter golden output and idempotence through the public `typelisp fmt` command. | `tests/format_golden/*.tl` and `selfhost/format_rules.tl` exist; no-Rust golden runner owned by #845. | Partial |
| `tests/integration.rs` | Linux compile, assemble, link, and run coverage for `tests/integration/*.tl`, selfhost smoke drivers, deterministic assembly, explicit build, and backend/runtime helper execution. | Source corpus and scripts (`verify-selfhost.sh`, `verify-stdlib.sh`, `verify-examples.sh`, `check-deterministic-asm.sh`) cover parts; full runner owned by #847. | Partial |
| `tests/lexer_compile.rs` | Legacy TypeLisp lexer witness compiles to assembly. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; delete Rust harness at #795 cutover. | Covered |
| `tests/maybe_result_compile.rs` | Monomorphic Maybe/Result witness compiles to assembly. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; delete Rust harness at #795 cutover. | Covered |
| `tests/nested_eval_compile.rs` | Nested pattern evaluator compiles to assembly. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; delete Rust harness at #795 cutover. | Covered |
| `tests/nullary_variant_call_compile.rs` | Nullary enum variant call-form witness compiles to assembly. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; delete Rust harness at #795 cutover. | Covered |
| `tests/package_build.rs` | Package manifest discovery, deterministic output paths, path dependencies, and package diagnostics. | Selfhost loader/package work is tracked by #834; public package harness owned by #845. | Gap |
| `tests/parser_compile.rs` | Legacy TypeLisp parser witness compiles to assembly. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; delete Rust harness at #795 cutover. | Covered |
| `tests/spec_examples.rs` | `SPEC.md` Lisp examples follow metadata and expected diagnostics. | No no-Rust SPEC fence runner yet; public docs/spec harness owned by #845. | Gap |
| `tests/sym_i64_env_compile.rs` | Selfhost `String -> i64` symbol table compiles to assembly. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; delete Rust harness at #795 cutover. | Covered |
| `tests/tl_ast_compile.rs` | Early selfhost Sexpr-to-AST parser and real compiler AST type model compile. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; delete Rust harness at #795 cutover. | Covered |
| `tests/tl_compiler_backend_compile.rs` | Selfhost backend, backend smoke/runtime fixture, driver, optimizer, build, and run modules compile and embed expected symbols/messages. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; runtime execution remains with #847. Delete Rust harness at #795 cutover. | Covered |
| `tests/tl_compiler_lower_compile.rs` | Selfhost IR types, lowerer, liveness, regalloc, and smoke drivers compile. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; delete Rust harness at #795 cutover. | Covered |
| `tests/tl_compiler_parse_compile.rs` | Selfhost compiler parser core and smoke driver compile and preserve parse diagnostics/smoke data. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; delete Rust harness at #795 cutover. | Covered |
| `tests/tl_compiler_symbols_compile.rs` | Selfhost symbol and registry modules compile and keep expected diagnostics/symbols. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; delete Rust harness at #795 cutover. | Covered |
| `tests/tl_compiler_typecheck_compile.rs` | Selfhost typecheck/check modules and smoke drivers compile. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; delete Rust harness at #795 cutover. | Covered |
| `tests/tl_doc_driver_compile.rs` | Selfhost documentation driver compiles with extractor and renderer imports. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; public behavior remains with #845. Delete Rust harness at #795 cutover. | Covered |
| `tests/tl_doc_extract_compile.rs` | Selfhost doc extractor and smoke policy fixtures compile. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; delete Rust harness at #795 cutover. | Covered |
| `tests/tl_doc_render_compile.rs` | Selfhost Markdown renderer and golden smoke fixtures compile. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; delete Rust harness at #795 cutover. | Covered |
| `tests/tl_doc_test_compile.rs` | Selfhost doctest extractor and policy fixtures compile. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; public doctest behavior remains with #845. Delete Rust harness at #795 cutover. | Covered |
| `tests/tl_emit_compile.rs` | Selfhost emitter demo compiles to assembly. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; executable behavior remains with #847. Delete Rust harness at #795 cutover. | Covered |
| `tests/tl_eval_compile.rs` | Selfhost evaluator compiles to assembly. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; executable behavior remains with #847. Delete Rust harness at #795 cutover. | Covered |
| `tests/tl_format_compile.rs` | Selfhost formatter core, CST/doc/rules, and driver modules compile. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; public golden behavior remains with #845. Delete Rust harness at #795 cutover. | Covered |
| `tests/tl_frontend_tools_compile.rs` | Selfhost frontend inspection CLI driver compiles. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; parse compatibility follow-up remains #843. Delete Rust harness at #795 cutover. | Covered |
| `tests/tl_lexer_compile.rs` | Selfhost TypeLisp lexer driver compiles to assembly. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; delete Rust harness at #795 cutover. | Covered |
| `tests/tl_lsp_frame_compile.rs` | Selfhost LSP framing driver compiles. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; protocol behavior remains with #845. Delete Rust harness at #795 cutover. | Covered |
| `tests/tl_parse_compile.rs` | Selfhost parser, parse core, and compile smoke driver compile. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; corpus execution remains in `scripts/verify-selfhost.sh`. Delete Rust harness at #795 cutover. | Covered |
| `tests/tl_reader_compile.rs` | Selfhost reader driver compiles with lexer/token imports. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; delete Rust harness at #795 cutover. | Covered |
| `tests/tl_repl_compile.rs` | Selfhost REPL driver compiles. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; interactive behavior remains with #845. Delete Rust harness at #795 cutover. | Covered |
| `tests/tl_text_buf_compile.rs` | Selfhost deterministic text buffer utility and driver compile. | Covered by `selfhost/COMPILE_MANIFEST.txt` via `scripts/verify-selfhost-compile-manifest.sh`; stdlib buffer work remains with #821. Delete Rust harness at #795 cutover. | Covered |
| `tests/windows_native.rs` | Windows target compile/link/run behavior, runtime helper cases, dependency staging, runtime args, stdout/stderr, and exit codes. | `verify-stdlib.sh` and `verify-examples.sh` have host-aware Windows paths; full platform runner owned by #847. | Partial |

## Maintenance Rules

- Any new `tests/*.rs` file or new Rust test case must update this table in the
  same PR with either a no-Rust replacement path or a follow-up issue.
- Rust `*_compile.rs` harnesses marked Covered by
  `selfhost/COMPILE_MANIFEST.txt` are retained only as temporary stage0
  reference tests until #795 can delete Cargo/Rust as a required path.
- Prefer adding TypeLisp fixtures under `selfhost/tests/`, `tests/integration/`,
  `tests/format_golden/`, or a dedicated corpus directory plus a manifest check.
- Rust tests can remain as temporary stage0 reference coverage only when this
  map states the deletion condition.
- When a no-Rust replacement lands, update the row status and close or retarget
  the linked follow-up issue.
