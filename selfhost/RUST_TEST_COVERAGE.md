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
- #846 replaces Rust compile/symbol smoke tests with a no-Rust selfhost compile
  manifest.
- #847 replaced Rust native integration and platform runners with no-Rust
  manifests and host-aware scripts.

## File Inventory

| Rust test file | Behavior protected | Replacement path | Status |
| --- | --- | --- | --- |
| `tests/backend_diagnostics.rs` | Backend rejection diagnostics preserve source locations for unsupported aggregate returns. | Covered by the manifest-backed `tests/diagnostics/backend/` corpus run by `scripts/verify-public-tools.sh`. | Covered |
| `tests/calc_compile.rs` | `tests/integration/calc.tl` compiles to assembly and keeps the tokenizer, parser, evaluator, and imported token model wired together. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/cli.rs` | Public CLI usage/errors and behavior for compile/check/build/run/fmt/doc/doc-test/debug/package-adjacent flows, LSP, REPL, and selfhost REPL. | `scripts/verify-public-tools.sh` now covers representative public CLI, docs, LSP, REPL, formatter, package, SPEC, and diagnostic cases; `doc --test` now routes through `selfhost/doc.tl`; remaining embedded edge cases still need migration. | Partial |
| `tests/fmt_golden.rs` | Formatter golden output and idempotence through the public `typelisp fmt` command. | Covered by `tests/format_golden/*.tl`, matching `*.expected` files, and the manifest/idempotence checks in `scripts/verify-public-tools.sh`. | Covered |
| `tests/integration.rs` | Linux compile, assemble, link, and run coverage for `tests/integration/*.tl`, selfhost smoke drivers, deterministic assembly, explicit build, and backend/runtime helper execution. | Covered by `scripts/verify-integration.sh`, `tests/integration/native-linux.manifest`, `scripts/check-deterministic-asm.sh`, and the narrower public/stdlib/selfhost verification scripts. | Covered |
| `tests/lexer_compile.rs` | Legacy TypeLisp lexer witness compiles to assembly. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/maybe_result_compile.rs` | Monomorphic Maybe/Result witness compiles to assembly. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/nested_eval_compile.rs` | Nested pattern evaluator compiles to assembly. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/nullary_variant_call_compile.rs` | Nullary enum variant call-form witness compiles to assembly. | Covered by `selfhost/compile_manifest.txt` and `scripts/verify-selfhost-compile-manifest.sh`; Rust harness can be deleted with #793/#795. | Covered |
| `tests/package_build.rs` | Package manifest discovery, deterministic output paths, path dependencies, and package diagnostics. | `scripts/verify-public-tools.sh` covers deterministic package output, path dependencies, manifest parse errors, and missing aliases; remaining package edge cases still need migration. | Partial |
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
| `tests/windows_native.rs` | Windows target compile/link/run behavior, runtime helper cases, dependency staging, runtime args, stdout/stderr, and exit codes. | Covered by the Windows path in `scripts/verify-integration.sh`, `tests/integration/native-windows.manifest`, and the host-aware Windows paths in `verify-stdlib.sh` and `verify-examples.sh`. | Covered |

## Maintenance Rules

- Any new `tests/*.rs` file or new Rust test case must update this table in the
  same PR with either a no-Rust replacement path or a follow-up issue.
- Prefer adding TypeLisp fixtures under `selfhost/tests/`, `tests/integration/`,
  `tests/format_golden/`, or a dedicated corpus directory plus a manifest check.
- Rust tests can remain as temporary stage0 reference coverage only when this
  map states the deletion condition.
- When a no-Rust replacement lands, update the row status and close or retarget
  the linked follow-up issue.
