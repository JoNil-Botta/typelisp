# Checked-in module declaration audit

This note records the disposition of every physical line reported by:

```powershell
rg -n '^\(module ' src stdlib tests tools
```

It follows the implicit file-identity migration from
[#4024](https://github.com/JoNil-Botta/typelisp/issues/4024), the fixture
follow-up in [#4618](https://github.com/JoNil-Botta/typelisp/issues/4618), and
the final dotted-import migration in
[#2454](https://github.com/JoNil-Botta/typelisp/issues/2454).

## Result

The current scan contains 92 lines:

| Classification | Matching lines | Rule |
| --- | ---: | --- |
| Embedded fixture boundary | 84 | Source strings and focused tests deliberately create module boundaries to exercise parsing, loading, symbols, typechecking, lowering, or generated modules. |
| Checked-in module identity | 8 | The declaration is part of the module or nominal-identity behavior under test. |
| Legacy compatibility identity | 0 | Dotted imports no longer have a separate filesystem-path-plus-module escape hatch. |
| Redundant file header | 0 retained | A header that merely repeats an inferred filename identity is omitted unless the declaration itself is test behavior. |

The first module in a multiline fixture string can begin after a quote and is
therefore not selected by the command. Such declarations remain covered by
their source-constructor tests; this audit inventories only physical
line-start matches.

## Embedded fixture boundaries

The 84 fixture lines occur in:

- `src/compiler_check_core.tl`
- `src/compiler_load.tl`
- `src/compiler_lower_tests.tl`
- `src/compiler_symbols.tl`
- `src/compiler_typecheck.tl`
- `src/tests/compiler_load_lazy_smoke.tl`
- `src/tests/compiler_lower_smoke.tl`
- `src/tests/compiler_typecheck_reverse_mixed_smoke.tl`
- `src/tests/compiler_typecheck_smoke.tl`
- `tests/inline/compiler_lower_body_index_cache.tl`

They cover multi-module programs, duplicate declarations, canonical and
generated identities, alias restoration, macro-created modules, nominal type
identity, and cross-module lowering.

## Checked-in module identities

| File | Why the declaration remains |
| --- | --- |
| `src/lex.tl` | The lexer module is consumed through its explicit public identity. |
| `src/read.tl` | The reader module is consumed through its explicit public identity. |
| `src/tests/canonical_import_default_first_smoke.tl` | The smoke asserts a deliberately dotted canonical identity. |
| `src/tests/semantic/index/import_dep.tl` | The semantic-index fixture asserts its nested dotted identity. |
| `tests/integration/clone_imported_nominal_dep.tl` | The declaration participates in imported nominal-type identity coverage. |
| `tests/safety/clone_imported_nominal_noncloneable_dep.tl` | The declaration participates in the corresponding rejection case. |
| `tests/spmd/package_callable/src/lib.tl` | The package fixture exposes the public `spmd_fixture` identity. |
| `tests/spmd/package_consumer/src/main.tl` | The package consumer retains its explicit entry identity. |

## Dotted-import constraint

An ordinary import now names only a canonical dotted module identity. Its
segments determine the resolved source path, and a loaded explicit
`(module ...)` declaration must agree with that identity. The removed
string-path form can no longer use one physical filename while asserting an
unrelated module name.

When adding a direct `(module ...)` line, keep it near a fixture name or
comment that explains which category above applies. If the identity only
repeats the inferred source identity and the declaration is not itself under
test, omit the header.
