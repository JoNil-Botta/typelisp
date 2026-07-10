# Checked-in module declaration audit

This note records the disposition of every physical line reported by:

```powershell
rg -n '^\(module ' src stdlib tests tools
```

It follows the implicit file-identity migration from [#4024](https://github.com/JoNil-Botta/typelisp/issues/4024) and is the fixture follow-up for [#4618](https://github.com/JoNil-Botta/typelisp/issues/4618). A `(module ...)` at the start of a physical line is retained only when it defines a test boundary, nested module, generated identity, or compatibility identity; it is not a normal file header.

## Result

The audit started with 98 matching lines. Ten matching file headers whose explicit and inferred identities were identical were removed. The remaining 88 lines are classified below:

| Classification | Matching lines | Rule |
| --- | ---: | --- |
| Intentional fixture | 64 | Embedded test source needs a module boundary to exercise parsing, lookup, typechecking, lowering, or loader behavior. |
| Nested-module coverage | 5 | The fixture deliberately creates multiple or duplicate module declarations in one source input. |
| Generated-module coverage | 13 | A macro or generated import needs a stable explicit module identity distinct from the file identity. |
| Legacy compatibility coverage | 6 | A checked-in helper intentionally overrides its inferred filename identity and is imported through that declared path. |
| Redundant file header | 0 retained | Remove only when the header equals the inferred identity and is not test behavior. |

The first module in a multiline fixture string begins after a quote and is therefore not selected by this command. Such declarations are covered by the named source constructors below; this audit only inventories the checked-in scan output.

## Intentional fixtures

| Location and matching count | Why the direct declarations remain |
| --- | --- |
| `src/compiler_check_core.tl` (2) | `compiler-check-qualified-export-cache-*-source` constructs multi-module cache fixtures. |
| `src/compiler_symbols.tl` (3) | `compiler-symbols-*-source` exercises module scopes, aliases, and comptime root aliases. |
| `src/compiler_typecheck.tl` (38) | The `compiler-typecheck-*-source` constructors cover module-local variants; qualified, dotted, and aliased imports; cleanup and unsafe imports; macro export, hygiene, and prelude ordering; generated-declaration imports; dispatch exports; and cross-module mismatches. Every matching line is inside one of these source strings. |
| `src/compiler_lower.tl` (10) | The `compiler-lower-*-source` constructors exercise imported stdlib wrappers, qualified modules, aliases, dotted imports, and imported aggregate/enum values. |
| `src/tests/compiler_lower_smoke.tl` (2) | `compiler-lower-smoke-*-source` uses inline source strings to cover local vector and public string-module lowering. |
| `src/tests/compiler_typecheck_smoke.tl` (7) | Lazy-summary, lazy-import, and qualified-enum source constructors use explicit fixture module identities for loader/typechecker assertions. |
| `tests/inline/compiler_lower_body_index_cache.tl` (1) | The inline source string switches to `main` to reproduce the body-index cache regression. |
| `src/compiler_load.tl` (1) | `compiler-load-import-alias-preserved-ok?` is an inline import-alias fixture. |

## Nested-module coverage

| Location and matching count | Why the direct declarations remain |
| --- | --- |
| `src/compiler_load.tl` (3) | `compiler-load-duplicate-module-ok?`, `compiler-load-nested-module-duplicate-ok?`, and `compiler-load-imported-duplicate-module-path-ok?` assert duplicate-module diagnostics. |
| `src/tests/compiler_typecheck_smoke.tl` (2) | `compiler-typecheck-smoke-nested-dotted-nominal-source` checks nested dotted nominal identity and lookup. |

## Generated-module coverage

| Location and matching count | Why the direct declarations remain |
| --- | --- |
| `src/compiler_specialize.tl` (3) | `compiler-generated-decl-cross-module-*-source` compares generated declaration identity across module boundaries. |
| `src/tests/compiler_typecheck_smoke.tl` (6) | `compiler-typecheck-smoke-module-macro-strategy-*-source` and `compiler-typecheck-smoke-decls-macro-cross-module-*-source` exercise macro-created module identities. |
| `tests/inline/module_macro_*_provider.tl` (3) | Provider identities are intentionally `tests.*`; their exported macros create generated modules and refer back to the provider identity. The nearby comments make this visible in `rg -C` output. |
| `tests/integration/compile_profile_generated_import_inert_dep.tl` (1) | The generated import names `generated.profile_generated_import_inert_dep`, not the filename identity. |

## Legacy compatibility coverage

| Location and matching count | Why the direct declarations remain |
| --- | --- |
| `tests/integration/compile_profile_cross_file_single_compilation_{a,b,c}.tl` (3) | The entry imports the short `cross_single_*` identities through explicit legacy module clauses while checking cross-file specialization reuse. |
| `tests/integration/struct_match_pattern_geom.tl` (1) | The fixture imports the explicit dotted `struct.match.geom` identity. |
| `tests/safety/thread_spawn_{unrelated_dotted_spawn_lib,i64_shadowed_atomic_arena_lib}.tl` (2) | The safety cases require `local.worker` and `shadow_arena` rather than their filename identities. |

## Removed redundant file headers

These headers matched their implicit file identities and were not themselves under test:

| File | Former explicit identity |
| --- | --- |
| `src/compiler_object.tl` | `compiler_object` |
| `tests/inline/unreachable_cli_helper_lib.tl` | `unreachable_cli_helper_lib` |
| `tests/integration/modules_helper.tl` | `modules_helper` |
| `tests/integration/serialize_toy_format.tl` | `serialize_toy_format` |
| `tests/integration/serialize_enum_fixture.tl` | `serialize_enum_fixture` |
| `tests/safety/import_arg_mismatch_lib.tl` | `import_arg_mismatch_lib` |
| `tests/safety/serialize_bad_object_finish_hook_format.tl` | `serialize_bad_object_finish_hook_format` |
| `tests/safety/serialize_missing_extra_decls_hook_format.tl` | `serialize_missing_extra_decls_hook_format` |
| `tests/safety/serialize_missing_object_hook_format.tl` | `serialize_missing_object_hook_format` |
| `tests/safety/serialize_missing_sequence_hook_format.tl` | `serialize_missing_sequence_hook_format` |

When adding a new direct `(module ...)` line, keep it near a fixture name or comment that states which table classification applies. If its identity is just the file's inferred identity, omit the header.
