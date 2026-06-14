# SPEC Coverage Matrix

This matrix tracks the implemented and specified behavior in `SPEC.md`
sections 2 through 11. It is intentionally row-oriented rather than prose-only
so future SPEC edits can update the behavioral row, coverage owner, and
follow-up link in the same change.

## Maintenance

When changing `SPEC.md` sections 2 through 11:

- Add or update a row here in the same PR as the SPEC change.
- Prefer an existing TypeLisp-owned gate before adding a new fixture:
  integration manifests, safety corpus, inline tests, doctests, selfhost smoke
  tests, stdlib tests, public-tool specs, or backend diagnostics.
- Use `GAP` only after reconciling those gates. Link an open issue for every
  independent uncovered behavior.
- For unsupported section 8 behavior, add or link negative/diagnostic coverage
  work instead of positive runtime coverage.

Status values:

- `Covered`: existing CI-owned coverage exercises the behavior.
- `Negative`: existing CI-owned coverage asserts rejection or a runtime trap.
- `GAP`: implemented behavior needs additional coverage.
- `Feature pending`: SPEC-defined behavior is not implemented yet; coverage is
  owned by the feature issue before positive tests can land.
- `Partial`: some implemented behavior is covered, but the row has remaining
  coverage work.

Primary coverage owners referenced below:

- `integration`: `tests/integration/*.tl` through
  `tests/integration/native-linux.manifest`,
  `tests/integration/native-windows.manifest`, and
  `scripts/verify-integration.sh`.
- `safety`: `tests/safety/manifest.txt` and
  `scripts/verify-safety-corpus.sh`.
- `stdlib`: `stdlib/tests/*.tl` through stdlib verification.
- `inline`: inline `(test ...)` discovery through
  `scripts/verify-inline-tests.sh`.
- `doctest`: `scripts/verify-doc-tests.sh` and doctest smoke modules.
- `public-tools`: JSON/spec fixtures and shell assertions under
  `tests/public-tools/` and `scripts/verify-public-tools.sh`.
- `selfhost-smoke`: selfhost smoke drivers in the integration manifests and
  `selfhost/compile_manifest.txt`.

## Section 2: Lexical Structure

| ID | SPEC section | Normative behavior | Implementation status | Coverage owner/test(s) | Gap status | Follow-up |
| --- | --- | --- | --- | --- | --- | --- |
| S2-001 | 2.1 | Reader/lexer recognizes the token set, delimiters, identifiers, core keywords, quote/quasiquote punctuation, dot, and EOF. | Implemented | `tests/integration/lexer.tl`, `tests/integration/parser.tl`, `selfhost/lexer.tl`, `selfhost/reader.tl`, `tests/inline/lexer_rust_coverage.tl`, `tests/format_golden/*` | Covered | - |
| S2-002 | 2.2 | Semicolon comments are skipped; public doc comment forms are only `;#` and `;:` with contiguous item attachment rules. | Implemented | `selfhost/doc_extract_smoke.tl`, `selfhost/doc_md_smoke.tl`, `selfhost/doc_site_smoke.tl`, doctest verification | Covered | - |
| S2-003 | 2.2 | `typelisp doc --test` extracts supported Markdown fences, handles `expect-error`, runnable doctest metadata, malformed fences, and package/multi-input reporting. | Implemented | `selfhost/doc_test_smoke.tl`, `scripts/verify-doc-tests.sh`, `scripts/verify-public-tools.sh` SPEC metadata scanner | Covered | - |
| S2-004 | 2.3 | String escapes for newline, tab, carriage return, backslash, and quote are decoded; unknown escapes remain literal today. | Implemented | `tests/integration/string_*`, `tests/integration/lexer.tl`, doctests and format golden fixtures | Covered | - |
| S2-005 | 2.4 | Integer literals default to `i64`; float literals default to `f64`; narrower/unsigned use explicit casts. | Implemented | `tests/integration/arithmetic.tl`, `tests/integration/f32_scalar.tl`, `tests/integration/overflow_casts.tl`, `tests/safety/integer_wrap_cast_defined.tl` | Covered | - |

## Section 3: Type System

| ID | SPEC section | Normative behavior | Implementation status | Coverage owner/test(s) | Gap status | Follow-up |
| --- | --- | --- | --- | --- | --- | --- |
| S3-001 | 3.1 | Primitive type set, sizes, scalar value behavior, `bool`, `char`, and `unit`. | Implemented | `tests/integration/arithmetic.tl`, `tests/integration/f32_scalar.tl`, `tests/integration/print_char.tl`, `tests/integration/unit_functions.tl`, `tests/integration/unit_main.tl` | Covered | - |
| S3-002 | 3.2 | Tuple, fixed-array, dynamic-array, and owned `String` source values; dynamic arrays reject invalid lengths and initialize live elements. | Implemented | `tests/integration/tuple_values.tl`, `tests/integration/fixed_array.tl`, `tests/integration/make_array_*.tl`, `tests/integration/string_*`, `tests/integration/array_push_aggregate.tl` | Covered | - |
| S3-003 | 3.2, 3.11 | Bare `str` and `bytes` are not by-value types; borrowed text uses `(& r str)`. | `str` implemented; `bytes` pending | `stdlib/tests/borrowed_str_gate.tl`, `stdlib/tests/string_caller_result_check.tl`, `tests/safety/runtime_type_literal_reject.tl` | Partial | #2686, #2783 |
| S3-004 | 3.3 | Function pointer types, direct calls, indirect calls, non-capturing lambdas, and capturing closure descriptor values. | Implemented | `tests/integration/function_pointer_values.tl`, `tests/integration/lambda_lift.tl`, `tests/integration/lambda_capture_*.tl`, `tests/integration/tail_indirect_closure.tl` | Covered | - |
| S3-005 | 3.4, 5.20 | Raw pointer type syntax is safe to mention/copy/pass; dereference/write/offset/cast/address conversion require `unsafe`. | Implemented | `tests/safety/raw_pointer_values_defined.tl`, `tests/safety/safe_raw_pointer_read_reject.tl`, `tests/safety/manual_arena_reset_unsafe_reject.tl`, `stdlib/tests/ffi_api.tl` | Covered | - |
| S3-006 | 3.4.1 | `(Box T)`, `box`, and `box-get` are the safe recursive aggregate indirection surface. | Feature pending except related finite-layout analysis | SPEC examples are `test=ignore`; no executable coverage expected until implementation | Feature pending | #2686, #2553 |
| S3-007 | 3.5.1 | Enums have 0-based tags, nullary and payload variants, global constructor/pattern names, exhaustive match, and heap-allocated returns. | Implemented | `tests/integration/enum_match.tl`, `tests/integration/enum_string_payload.tl`, `tests/integration/nullary_variant_call.tl`, `tests/integration/string_match.tl`, `tests/safety/invalid_struct_field_reject.tl` for aggregate diagnostics | Covered | - |
| S3-008 | 3.5.2 | Structs have call-like constructors, field access, field-place mutation, heap-allocated returns, and no struct globals. | Implemented | `tests/integration/struct_field_set.tl`, `tests/integration/register_pair_struct.tl`, `tests/safety/struct_field_set_*_reject.tl`, `tests/integration/aggregate_globals.tl` | Covered | - |
| S3-009 | 3.5.3 | Default inline layout metadata and `(:repr c)` compatibility preserve declaration-order field offsets and enum tagged-union layout. | Implemented in metadata/layout paths; C ABI lowering separately validated | `tests/integration/repr_c_f32_fields.tl`, `tests/integration/nested_repr_c_aggregate.tl`, `tests/integration/array_stride_24byte.tl`, `tests/integration/ptr_offset_inline_aggregate_stride.tl`, C ABI fixtures | Covered | - |
| S3-010 | 3.6, 3.7 | No type aliases, source-level generics, traits, interfaces, generic functions, or `impl`; use monomorphic or generated declarations. | Implemented as current language policy | `tests/integration/generated_option_result_families.tl`, parser/typechecker smoke tests, public diagnostics | Partial | #2686 |
| S3-011 | 3.7.1 | `comptime-decl` and `comptime-decls` generated declarations, identity, duplicate policy, and allowed payload kinds. | Implemented for current selfhost path | `tests/integration/generated_option_result_families.tl`, `selfhost/compiler_ctfe_smoke.tl`, `selfhost/compiler_typecheck_reflection_smoke.tl` | Partial | #2686 |
| S3-012 | 3.7.2, 3.7.2.1 | Typed expression macro signatures, expression/clause captures, quote/quasiquote, expansion checks, and comptime purity restrictions. | Partially implemented through current macro/prelude path; stdlib-owned public surface still staged | `tests/integration/implicit_core_prelude.tl`, `tests/integration/cond.tl`, `stdlib/tests/core_macros_*.tl`, selfhost macro smoke tests | GAP | #2686 |
| S3-013 | 3.7.2.2, 3.7.3 | Stdlib-owned `Expr`/`TypeInfo` shapes and hygienic macro expansion rules. | Feature pending | SPEC examples are `test=ignore`; no positive coverage expected until implementation | Feature pending | #2686, #2653 |
| S3-014 | 3.8 | Numeric casts implement the scalar matrix; non-numeric casts are statically rejected; no implicit conversions. | Implemented | `tests/integration/overflow_casts.tl`, `tests/integration/u64_float_casts.tl`, `tests/safety/integer_wrap_cast_defined.tl`, `tests/safety/unsupported_cast_reject.tl` | Covered | - |
| S3-015 | 3.9 | Region-tagged types from `with-arena` do not change ABI and cannot escape region scope or v1 function boundaries. | Implemented for current region-checker surface | `tests/integration/with_arena_*.tl`, `tests/integration/arena_escape_stress.tl`, `tests/safety/region_escape_reject.tl`, `tests/safety/reference_region_defined.tl` | Covered | - |
| S3-016 | 3.10, 3.10.1 | Reference type syntax, explicit borrows, immutable auto-borrowing, lexical lifetime names, stored/returned lifetime-parameterized aggregates, and escape diagnostics. | Implemented for current selfhost slices; NLL deferred | `tests/integration/auto_borrow_call.tl`, `tests/integration/lifetime_*.tl`, `tests/integration/ref_*.tl`, `tests/safety/auto_borrow_*_reject.tl`, `stdlib/tests/vector_slice_*.tl` | Partial | #2686, #810 |
| S3-017 | 3.10.2 | Immutable reference captures are allowed only for proven non-escaping closures; escaping captures reject. | Implemented | `tests/integration/lambda_capture_lifetime_aggregate.tl`, `tests/integration/register_group_borrowed_match.tl`, `tests/safety/region_escape_reject.tl` | Partial | #2686 |
| S3-018 | 3.11 | Owned `String` and borrowed `str` source model, auto-borrowed text APIs, caller-result compatibility, and arena escape rules. | Implemented for borrowed `str`; compatibility builtins remain | `stdlib/tests/borrowed_str_gate.tl`, `stdlib/tests/string_caller_result_check.tl`, `stdlib/tests/io_caller_result_check.tl`, `tests/integration/stdlib_string.tl`, `tests/integration/string_*` | Covered | - |
| S3-019 | 3.11 | `ByteBuf`, `(& r bytes)`, and `(&mut r bytes)` binary storage contract and conversions. | Feature pending | No positive coverage yet; compatibility byte paths use `String` or `(Array u8)` | Feature pending | #2783, #2784 |

## Section 4: Top-Level Forms

| ID | SPEC section | Normative behavior | Implementation status | Coverage owner/test(s) | Gap status | Follow-up |
| --- | --- | --- | --- | --- | --- | --- |
| S4-001 | 4.1 | Global `define` accepts typed or inferred scalar, string, and aggregate initializers, using generated runtime initializer functions when needed. | Implemented | `tests/integration/global_initializer.tl`, `tests/integration/aggregate_globals.tl`, `selfhost/compiler_lower.tl` global initializer shape tests, `selfhost/compiler_backend_tests.tl` global data/runtime-global shape tests | Covered | - |
| S4-002 | 4.2 | Function `define` requires typed parameters, defaults return to `unit`, supports recursion, entry `main`, synthesized main, and rejects varargs outside externs. | Implemented | `tests/integration/functions.tl`, `tests/integration/factorial.tl`, `tests/integration/unit_functions.tl`, `tests/integration/unit_main.tl`, parser diagnostics | Covered | - |
| S4-003 | 4.3 | Extern forms, exact symbol/link metadata, function pointers, varargs markers, link input dedup, and ABI-supported signatures. | Implemented | `selfhost/compiler_parse_core.tl` extern metadata/varargs tests, `selfhost/compiler_typecheck.tl` extern ABI tests, `selfhost/compiler_backend_tests.tl` extern metadata/function-pointer/varargs tests, C ABI fixtures, `tests/safety/foreign_abi_metadata_reject.tl`, `stdlib/tests/ffi_api.tl`, public-tool build/link coverage | Covered | - |
| S4-004 | 4.3.1 | `(unsafe declaration)` gates safe calls/references to unsafe functions and externs. | Implemented | `selfhost/compiler_parse_core.tl` unsafe declaration tests, `selfhost/compiler_typecheck.tl` unsafe declaration tests, `tests/safety/safe_raw_pointer_read_reject.tl`, `tests/safety/foreign_abi_metadata_reject.tl`, raw-pointer fixtures | Covered | - |
| S4-005 | 4.4 | Legacy path imports resolve relative, absolute, stdlib-root, env fallback, embedded stdlib, package dependency, and deduplicated module paths. | Implemented | `tests/integration/modules_main.tl`, `tests/safety/import_arg_mismatch_root.tl`, public-tool LSP/import fixtures, package build coverage | Covered | - |
| S4-006 | 4.4.1-4.4.4 | Dotted module identities, aliases, exports/visibility, qualified lookup, and macro export/import ordering. | Partially implemented; repository migration/removal ongoing | `tests/integration/implicit_core_prelude.tl`, public-tool LSP/import fixtures, `selfhost/compiler_load.tl` dotted/package import smokes, `selfhost/compiler_typecheck.tl` macro import/export smokes | Partial | #2453, #2454 |
| S4-007 | 4.4.5 | TypeLisp linker symbol identity uses canonical module identity and declaration identity; extern/runtime symbols stay exact. | Implemented in current backend symbol model | `selfhost/compiler_lower.tl` package-owned symbol tests, `selfhost/compiler_backend_smoke.tl`, `selfhost/compiler_backend_tests.tl` extern metadata tests, `selfhost/compile_manifest.txt`, C ABI fixtures | Covered | - |
| S4-008 | 4.4.6 | `include-str` embeds UTF-8 text with import-like path resolution and diagnostics. | Implemented | `selfhost/compiler_parse_core.tl` include-str parser tests, `selfhost/compiler_load.tl` include-str relative/stdlib-root/missing/raw-text loader tests, `selfhost/compiler_embedded_stdlib.tl` | Covered | - |
| S4-009 | 4.4.7 | `include-bin` embeds exact binary bytes as `(Array u8)` with import-like path resolution and diagnostics. | Implemented | `selfhost/compiler_parse_core.tl` include-bin parser tests, `selfhost/compiler_load.tl` include-bin relative/missing/binary loader tests, `tests/integration/include_bin.tl` | Covered | - |
| S4-010 | 4.4.8 | Top-level and expression `cfg` predicates support names, `all`, `any`, `not`, target OS predicates, and inactive-branch parsing rules. | Implemented | `selfhost/compiler_parse_core.tl` cfg parser tests, `selfhost/compiler_load.tl` cfg import tests, `scripts/check-stage1-wrapper.sh`, `scripts/check-codegen-target-parity.sh` | Covered | - |
| S4-011 | 4.5 | Inline `(test ...)` items are ignored by production commands and owned by `typelisp test` harness generation. | Implemented | `scripts/verify-inline-tests.sh`, `tests/inline/*.tl`, `stdlib/tests/*`, `selfhost/test_cli_core.tl` | Covered | - |
| S4-012 | 4.6 package | `typelisp.pkg` manifests, kind/entry defaults, local and git dependencies, lockfile replay/update, package cache, DAG builds, and package output paths. | Implemented | `scripts/check-stage1-wrapper.sh`, `scripts/verify-public-tools.sh`, `selfhost/compiler_load.tl` package manifest/import tests, `selfhost/build_cli_core.tl` tests, `selfhost/package_lock_smoke.tl`, `selfhost/package_cache_smoke.tl` | Covered | - |
| S4-013 | 4.6 defenum/defstruct | Top-level `defenum` and `defstruct` behavior delegates to the type-system rules. | Implemented | Enum/struct integration fixtures and parser/typechecker smokes | Covered | - |
| S4-014 | 4.6.1 | Cleanup-owning struct declarations, field cleanup metadata, generated cleanup function, LIFO field cleanup, and escape/copy restrictions. | Implemented for structs; cleanup-owning enum metadata typechecks while enum cleanup lowering remains reserved | `selfhost/compiler_parse_core.tl` cleanup metadata tests, `selfhost/compiler_typecheck.tl` cleanup struct/resource/move tests, `selfhost/compiler_lower.tl` cleanup struct shape tests | Covered | - |
| S4-015 | 4.6.2 | Move-only aggregate handle checking, path moves/reinitialization, non-consuming inspection, loop conservatism, and diagnostics. | Implemented | `selfhost/compiler_typecheck.tl` move checker fixtures, `tests/integration/clone_deep_copy.tl`, `tests/integration/array_push_aggregate.tl`, `tests/safety/auto_borrow_*_reject.tl` | Covered | - |
| S4-016 | 4.6.3 | Recursive inline aggregate cycles require explicit indirection; finite-layout analysis rejects unboxed cycles. | Implemented finite-layout analysis | `selfhost/compiler_typecheck.tl` recursive aggregate layout fixtures, boxed list/tree acceptance tests, inline-cycle diagnostics | Covered | - |

## Section 5: Expressions

| ID | SPEC section | Normative behavior | Implementation status | Coverage owner/test(s) | Gap status | Follow-up |
| --- | --- | --- | --- | --- | --- | --- |
| S5-001 | 5.1 | Literal forms produce their specified types. | Implemented | `tests/integration/arithmetic.tl`, `tests/integration/f32_scalar.tl`, `tests/integration/print_char.tl`, `tests/integration/string_length.tl`, SPEC doctests | Covered | - |
| S5-002 | 5.2 | Lexical scoping and variable lookup order prefer locals, parameters, then globals. | Implemented | `tests/integration/control_flow.tl`, `tests/integration/functions.tl`, parser/typechecker smokes | Covered | - |
| S5-003 | 5.3 | Direct/indirect calls evaluate arguments left-to-right, pass register and stack args, and handle function pointer values. | Implemented | `tests/integration/function_pointer_values.tl`, `tests/integration/many_args.tl`, `tests/integration/tail_call_stack_args.tl`, C ABI fixtures | Partial | #2688 |
| S5-004 | 5.4 | Integer arithmetic wraps where specified; division/remainder and invalid shifts trap deterministically; floats support accepted arithmetic. | Implemented | `tests/integration/arithmetic.tl`, `tests/integration/div_zero_trap.tl`, `tests/integration/min_div_neg1_trap.tl`, `tests/integration/shl_*_trap.tl`, `tests/safety/*trap.tl`, `tests/integration/f32_scalar.tl` | Covered | - |
| S5-005 | 5.5 | Comparisons support integer and float types; string equality uses string helpers. | Implemented | `tests/integration/arithmetic.tl`, `tests/integration/f32_scalar.tl`, `tests/integration/string_eq.tl` | Covered | - |
| S5-006 | 5.6 | `if`, flat `cond`, `when`, and `unless` enforce boolean tests and branch/body typing. | Implemented | `tests/integration/control_flow.tl`, `tests/integration/cond.tl`, `stdlib/tests/core_macros_*.tl` | Covered | - |
| S5-007 | 5.7-5.11 | `let`, `begin`, `while`, `set!`, and `ann` sequencing, typing, mutation, and unit behavior. | Implemented | `tests/integration/control_flow.tl`, `tests/integration/struct_field_set.tl`, `selfhost/tests/*.tl`, `tests/safety/struct_field_set_*_reject.tl` | Covered | - |
| S5-008 | 5.12 | Expression `cast` delegates to the section 3.8 scalar matrix. | Implemented | `tests/integration/overflow_casts.tl`, `tests/integration/u64_float_casts.tl`, `tests/safety/unsupported_cast_reject.tl` | Covered | - |
| S5-009 | 5.12.1 | Explicit and contextual `init` build valid ZII values or reject unsupported/ambiguous cases. | Implemented for current eligible surface | `tests/integration/make_array_init.tl`, `tests/integration/make_array_zero.tl`, `tests/integration/fixed_array.tl`, parser/typechecker smokes | GAP | #2688 |
| S5-010 | 5.13 | `match` supports enum, borrowed enum, scalar, string literal, wildcard, exhaustive arms, payload bindings, and arm type merging. | Implemented for current surface | `tests/integration/enum_match.tl`, `tests/integration/string_match.tl`, `tests/integration/register_group_borrowed_match.tl`, `tests/integration/lifetime_enum_borrow_return.tl` | Partial | #2688 |
| S5-011 | 5.14 | Lambdas cover non-capturing lowering, capturing environments, aggregate captures/returns, fixed-array captures, and mutable-capture rejection. | Implemented; captured-name assignment is rejected by design | `tests/integration/lambda_*.tl`, `tests/integration/tail_indirect_closure.tl`, `selfhost/compiler_typecheck.tl` | Partial | #2688 |
| S5-012 | 5.15 | `foreach` scalar semantics, contiguous map/zip lowering, tail masks, supported lane types, uniform/varying rules, and SPMD safety rejections. | Implemented for current slice | `tests/integration/spmd_foreach.tl`, `tests/spmd/*.tl`, `scripts/verify-spmd-simd.sh`, `tests/safety/spmd_*_reject.tl` | Covered | - |
| S5-013 | 5.15 | Public `(program-index)` and `(program-count)` lane identity forms. | Feature pending | SPEC examples are ignored until implementation | Feature pending | #2761, #2688 |
| S5-014 | 5.15 | Masked varying `if` source semantics and unsupported branch restrictions. | Feature in flight; negative restrictions covered | `tests/safety/spmd_masked_if_*_reject.tl`, `tests/spmd/masked_if_*.tl` for staged work | Partial | #2131, #2207, #2688 |
| S5-015 | 5.15 | `spmd-reduce` operators, supported types, empty range semantics, purity rules, and SIMD vectorization subset. | Implemented for current slice | `tests/integration/spmd_reduce_scalar.tl`, `benchmarks/spmd_reduce/bench.tl`, `tests/safety/spmd_reduce_f64_min_reject.tl`, `scripts/verify-spmd-simd.sh` | Covered | - |
| S5-016 | 5.15 | Runtime SIMD dispatch `defdispatch` validates variants and selects cached best supported backend. | Implemented | `tests/spmd/runtime_dispatch_select.tl`, `scripts/verify-spmd-runtime-dispatch.sh`, `stdlib/tests/cpu_api.tl` | Covered | - |
| S5-017 | 5.16 | `with-arena` scopes allocation, rejects escapes, supports nested regions, and lowers to mark/reset on Linux and Windows. | Implemented | `tests/integration/with_arena_*.tl`, `tests/integration/arena_escape_stress.tl`, `tests/safety/region_escape_reject.tl` | Covered | - |
| S5-018 | 5.16, 7.3 | `with-escape` clones supported results out of a first-class scratch arena and rewinds the scratch arena. | Implemented for current cloneable surface | `tests/integration/with_escape_clone_out.tl`, `stdlib/tests/arena_patterns.tl` | Partial | #2688 |
| S5-019 | 5.17 | Comptime reflection primitives, type keys, nominal metadata, array/function/struct/enum indexing, and runtime rejection. | Implemented selfhost v1 | `tests/integration/comptime_scalar.tl`, `selfhost/compiler_typecheck_reflection_smoke.tl`, `selfhost/compiler_ctfe_smoke.tl`, `tests/safety/runtime_type_literal_reject.tl` | Partial | #2688 |
| S5-020 | 5.17.1 | `.tlci` container/header/hash/metadata helpers validate and round-trip images; package builds emit metadata-only images; `typelisp inspect` renders valid images and reports parser diagnostics. | Metadata-only package emission and inspect implemented; export population plus code-bearing emission/loading staged | `selfhost/tlci_core_smoke.tl`, `selfhost/tlci_core.tl` inline tests, `scripts/check-stage1-wrapper.sh`, `scripts/verify-public-tools.sh`, `scripts/verify-selfhost-cli-build-run.sh` | Partial | #2688, #2912 |
| S5-021 | 5.18 | Compile-time `size-of`, `align-of`, and `offset-of` layout queries reject invalid use and produce stable metadata. | Implemented | `tests/integration/repr_c_f32_fields.tl`, `tests/integration/nested_repr_c_aggregate.tl`, `selfhost/compiler_typecheck_reflection_smoke.tl` | Partial | #2688 |
| S5-022 | 5.19 | Resource `with` initializes left-to-right, cleans LIFO, prevents resource escape, and composes with future recoverable propagation. | Implemented for current resource cleanup surface | Stdlib IO/process tests, selfhost typechecker/lowerer smokes | GAP | #2688 |
| S5-023 | 5.20 | `unsafe` expression blocks permit only explicitly unsafe raw-pointer/syscall/manual-arena operations while preserving ordinary typechecking. | Implemented | `tests/safety/safe_raw_pointer_read_reject.tl`, `tests/safety/safe_syscall_reject.tl`, `tests/safety/unsafe_syscall_defined.tl`, `tests/safety/manual_arena_reset_unsafe_reject.tl`, `stdlib/tests/ffi_api.tl`, `stdlib/tests/arena_api.tl` | Covered | - |

## Section 6: Built-in Functions and Runtime

| ID | SPEC section | Normative behavior | Implementation status | Coverage owner/test(s) | Gap status | Follow-up |
| --- | --- | --- | --- | --- | --- | --- |
| S6-001 | 6.1 | Builtin print, array, string, concat, parse/format, panic/error, and alias signatures behave as specified and trap on bounds/invalid lengths. | Implemented | `tests/integration/print*.tl`, `tests/integration/string_*.tl`, `tests/integration/stdlib_string.tl`, `tests/integration/make_array_*_trap.tl`, `tests/integration/stdlib_substring_*_trap.tl`, safety corpus | Covered | - |
| S6-002 | 6.2 | Backend emits allocator, ordinary arena, string, and trap runtime helpers without a separate C runtime; Linux/Windows page paths and TLS/current-arena policy are target-owned; atomic arena creation/allocation remains split out. | Ordinary allocator/arena implemented; atomic arena runtime pending | `tests/integration/tl_alloc.tl`, `tests/integration/tl_alloc_huge_trap.tl`, `tests/integration/region_*.tl`, `tests/integration/thread_runtime.tl`, native link scripts, `selfhost/compiler_backend_tests.tl` runtime inventory/page-call tests | Partial | #2642 |
| S6-003 | 6.3 | Operator aliases expand to their canonical builtin/helper forms. | Implemented | `tests/integration/string_eq.tl`, `tests/integration/substring.tl`, `tests/integration/print_string.tl`, stdlib tests | Covered | - |
| S6-004 | 6.4 | `stdlib/io.tl` file handle API covers opaque handles, open modes, close/double-close errors, streaming read/write/flush, and platform unsupported results. | Implemented for current stdlib surface | `stdlib/tests/io_file_handle.tl`, `stdlib/tests/io_edges.tl`, `tests/integration/stdlib_io.tl`, `tests/integration/read_file_missing_trap.tl`, `tests/integration/write_file_invalid_trap.tl` | Covered | - |
| S6-005 | 6.5 | Safe task threading, structural transfer/share classification, safe spawn/join, mutex guards, channels, and atomics. | Feature pending, with raw substrate/runtime pieces present | `tests/integration/thread_runtime.tl`, `tests/integration/sync_channel_thread_runtime.tl`, `stdlib/tests/thread_api.tl`, `stdlib/tests/sync_api.tl` cover current raw/std surfaces | Feature pending | #2714, #2715, #2716, #2717 |

## Section 7: Memory Model

| ID | SPEC section | Normative behavior | Implementation status | Coverage owner/test(s) | Gap status | Follow-up |
| --- | --- | --- | --- | --- | --- | --- |
| S7-001 | 7.1 | Stack slots, downward stack growth, compile-time frame sizing, and 16-byte call alignment. | Implemented | `tests/integration/many_args.tl`, `tests/integration/register_scalar_homes.tl`, `selfhost/compiler_backend_tests.tl` stack/call-shape tests, C ABI fixtures | Covered | - |
| S7-002 | 7.2 | Heap allocation goes through `tl_alloc`; no GC or general `free`; per-thread default arenas live to program/thread lifetime. | Implemented | `tests/integration/tl_alloc.tl`, `tests/integration/tl_alloc_huge_trap.tl`, `tests/integration/thread_runtime.tl`, region tests | Covered | - |
| S7-003 | 7.3 | `with-arena` is the safe scoped reclamation surface; active-arena allocation policy rejects region escapes. | Implemented | `tests/integration/with_arena_*.tl`, `tests/integration/region_*.tl`, `tests/safety/region_escape_reject.tl`, `stdlib/tests/arena_policy*.tl` | Covered | - |
| S7-004 | 7.3 | Lifetime owner classes and lexical outlives model constrain references, regions, first-class arenas, and atomic arenas. | Lexical references/regions and ordinary first-class arena helpers implemented; `in-arena` and atomic arena slices pending | Reference/arena safety corpus, `selfhost/compiler_typecheck_smoke.tl`, `stdlib/tests/arena_api.tl`, `stdlib/tests/arena_patterns.tl`, `stdlib/tests/arena_policy*.tl` | Partial | #2625, #2642 |
| S7-005 | 7.3 | `with-escape` and manual arena helpers distinguish safe clone-out from unsafe invalidating reset/destroy. | Implemented | `tests/integration/with_escape_clone_out.tl`, `stdlib/tests/arena_api.tl`, `stdlib/tests/arena_patterns.tl`, `tests/safety/manual_arena_reset_unsafe_reject.tl` | Covered | - |
| S7-006 | 7.3 | Atomic arena allocation target and safe cross-thread owner policy. | Feature pending | Current raw thread/sync smoke only; no safe structural transfer corpus yet | Feature pending | #2642, #2717 |
| S7-007 | 7.4 | Raw pointers are nullable/copyable address values; unsafe memory operations carry caller obligations. | Implemented | Raw-pointer safety fixtures and `stdlib/tests/ffi_api.tl` | Covered | - |
| S7-008 | 7.5 | Globals live in data/rodata, string literal bytes are rodata, and `String` points at inline ptr/len storage. | Implemented | `tests/integration/global_initializer.tl`, `tests/integration/aggregate_globals.tl`, `tests/golden/*.s`, `selfhost/compiler_backend_tests.tl` global/string data-shape tests | Covered | - |
| S7-009 | 7.6 | Aggregate handles are move-only source values, non-consuming inspection is compatibility borrow-like behavior, mutation requires owned/mutable access, returns may heap-promote, and `clone` deep-copies supported shapes. | Implemented for current checker/lowering | `tests/integration/clone_deep_copy.tl`, `tests/integration/array_push_aggregate.tl`, `tests/integration/register_resident_*`, `tests/safety/struct_field_set_*_reject.tl`, `selfhost/compiler_typecheck.tl` move-checker fixtures | Covered | - |

## Section 8: Backend Capabilities and Limitations

| ID | SPEC section | Normative behavior | Implementation status | Coverage owner/test(s) | Gap status | Follow-up |
| --- | --- | --- | --- | --- | --- | --- |
| S8-001 | 8.1 | Supported backend surface includes scalar arithmetic, floats, bool/char/unit, control flow, calls, locals/globals, casts, enums, structs, arrays, strings, stdlib I/O/FFI, imports, and native Linux/Windows targets. | Implemented | Integration manifests, stdlib tests, native link scripts, backend smoke tests, public-tool build/run coverage | Covered | - |
| S8-002 | 8.2 | Implemented limitations table entries stay covered as they move from unsupported to supported: tuple ABI, fixed-array returns, aggregate globals, raw pointers, move checking, `with`, SPMD, defdispatch, package manager, REPL, LSP. | Implemented where marked implemented | Existing fixtures named in sections 3-7 and 10 | Partial | #2690 |
| S8-003 | 8.2 | Mutable lambda captured-name assignment is formally rejected. | Rejected by design | `selfhost/compiler_typecheck.tl` captured assignment negative and shadowing-positive cases | Covered | - |
| S8-004 | 8.2 | Indirect and closure tail calls remain separate from implemented direct/self tail jumps. | Partially implemented | `tests/integration/tail_*.tl` cover direct/self/stack and current indirect closure behavior | Partial | #2363, #2690 |
| S8-005 | 8.2 | Unsupported SPMD features remain negative/diagnostic work: public lane ids, gathers/scatters, cross-lane ops, atomics, public vector/mask values, varying control-flow leftovers, varying calls, unsupported lane values. | Partially covered by negative safety corpus; feature issues open | `tests/safety/spmd_*_reject.tl`, `tests/safety/spmd_masked_if_*_reject.tl` | Partial | #2761, #2762, #2764, #2765, #2766, #2768, #2690 |
| S8-006 | 8.2 | Complete source locations for all semantic errors remain partial. | Partial | Safety corpus checks diagnostic substrings; public-tool LSP diagnostics cover selected spans | GAP | #2690 |

## Section 9: Error Handling

| ID | SPEC section | Normative behavior | Implementation status | Coverage owner/test(s) | Gap status | Follow-up |
| --- | --- | --- | --- | --- | --- | --- |
| S9-001 | 9 | `panic` and `error` print to stderr, exit 134, have `never`, and merge into branch/match result types. | Implemented | `tests/integration/read_file_missing_trap.tl`, `tests/integration/write_file_invalid_trap.tl`, `tests/integration/stdlib_substring_*_trap.tl`, SPEC compile examples through doctest/public tools | Covered | - |
| S9-002 | 9 | Function-local `(return expr)` has bottom type, is valid only inside functions/lambdas, and runs active `with` cleanup and `with-arena` resets. | Implemented for current selfhost return surface | `tests/integration/early_return.tl`, `tests/integration/control_flow.tl`, cleanup/arena fixtures | Partial | #2690 |
| S9-003 | 9 | Recoverable error and option families are concrete enums generated by comptime identity, not generic traits/type erasure. | Implemented for generated declarations and hand-written monomorphic families | `tests/integration/maybe_result.tl`, `tests/integration/generated_option_result_families.tl`, SPEC compile examples | Covered | - |
| S9-004 | 9 | `(try expr)` propagates compatible Result-like families; Option-like propagation and incompatible-family diagnostics need coverage. | Result-like implemented; Option-like tracked separately | `tests/integration/register_group_try.tl`, SPEC ignored examples | Partial | #1979, #2690 |

## Section 10: CLI

| ID | SPEC section | Normative behavior | Implementation status | Coverage owner/test(s) | Gap status | Follow-up |
| --- | --- | --- | --- | --- | --- | --- |
| S10-001 | 10 | Root command list and common options expose `build`, `check`, `compile`, `doc`, `fmt`, `init`, `inspect`, `lint`, `lsp`, `new`, `repl`, `run`, and `test`. | Implemented | `tests/public-tools/cli-command-surface.txt`, `scripts/verify-public-tools.sh`, selfhost command wrappers in compile manifest | Covered | - |
| S10-002 | 10 | `compile`, `build`, `run`, package build, opt-level/profile/lock flags, stdlib roots, cfg, target/backend mode, batch, and emit-ir behave as command-specific help says. | Implemented | `scripts/verify-public-tools.sh`, `scripts/verify-selfhost-cli-build-run.sh`, package smoke tests, `scripts/check-codegen-target-parity.sh` | Partial | #2690 |
| S10-003 | 10 | `fmt`, `lint`, `test`, doctest/doc generation, and default package discovery use public CLI semantics. | Implemented | `scripts/check-tl-format.sh`, `scripts/check-tl-lint.sh`, `scripts/verify-inline-tests.sh`, `scripts/verify-doc-tests.sh`, `scripts/verify-doc-site.sh` | Covered | - |
| S10-004 | 10 | `repl` supports `.help`, `.type`, `.exit`, remembers declarations, evaluates expressions through scratch build/run, and recovers from errors. | Implemented | `tests/public-tools/repl/*`, `tests/public-tools/selfhost-repl/*`, `scripts/verify-public-tools.sh` | Covered | - |
| S10-005 | 10 | Linux build/run uses `as` and `ld`; Windows build/run uses Clang/lld-link and CRT-linked runtime helpers. | Implemented | `scripts/verify-native-link-linux.sh`, `scripts/verify-native-link-windows.sh`, integration manifests | Partial | #2690 |

## Section 11: ABI Reference

| ID | SPEC section | Normative behavior | Implementation status | Coverage owner/test(s) | Gap status | Follow-up |
| --- | --- | --- | --- | --- | --- | --- |
| S11-001 | 11.1 | System V AMD64 uses independent integer/float argument register sequences, stack args, return registers, callee-saved registers, and 16-byte call alignment. | Implemented | `tests/integration/c_abi_sysv_register_aggregate_args.tl`, `tests/integration/c_abi_sysv_tag_only_enum.tl`, `tests/integration/many_args.tl`, backend smoke tests | Partial | #2690 |
| S11-002 | 11.2 | Windows x64 uses shared four-register slots, shadow space, return registers, and CRT-owned startup with `main`. | Implemented | `tests/integration/c_abi_win64_*.tl`, `tests/integration/many_args.tl`, `scripts/verify-native-link-windows.sh`, backend smoke tests | Partial | #2690 |
| S11-003 | 11.3 | Data layout uses stable primitive sizes/alignment, pointer-sized handles, declaration-order structs, tagged-union enums, and `(:repr c)` as compatibility metadata only. | Implemented | `tests/integration/repr_c_f32_fields.tl`, `tests/integration/nested_repr_c_aggregate.tl`, `tests/integration/array_stride_24byte.tl`, `tests/integration/ptr_offset_inline_aggregate_stride.tl`, layout query smoke tests | Partial | #2690 |
