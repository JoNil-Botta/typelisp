# Compiler architecture

This is the current design entry point, open to evidence-backed improvement.
[README](../README.md) defines the native, self-hosted, dependency-free,
arena/ownership and SPMD direction; [SPEC](../SPEC.md) defines semantics.
Before changing compiler structure or a shared interface, read the affected
records below and the [testing contract](../src/TESTING.md).

## Pipeline and boundaries

The lexer/reader and parser produce `AstProgram`. The loader resolves source
identities and imports; macro expansion can produce more declarations and
imports. Typechecking supplies checked expression and ownership facts.
Lowering produces typed three-address IR, optimization transforms that IR,
and the backend emits native code for the selected target. CLI, package,
batch and LSP services orchestrate these stages.

Compilation deduplicates the import graph for one whole program per executable.
Package dependencies can be compiled into archives. Batch and LSP paths reuse
session state only within its owner and invalidation contracts.

| Shared fact | Canonical implementation | Consumer obligation |
| --- | --- | --- |
| Syntax and pooled AST nodes | [parser](../src/compiler_parse_core.tl), [AST model](../src/compiler_ast_types.tl) | Reuse parsing and `ast-expr-child-ids`/`ast-expr-children`; carry the node's owner. |
| Source/import identity | [loader](../src/compiler_load.tl) | Reuse its resolver and parsed surface facts; a surface is not a complete expanded or checked program. |
| Checked expressions and ownership | [typechecker](../src/compiler_typecheck_core.tl), [public entry points](../src/compiler_typecheck_api.tl) | Use context-owned facts; invalidate them when their semantic inputs or owners change. |
| Shared IR and operands | [IR model](../src/compiler_ir_types.tl) | Extend `compiler-ir-instr-visit-uses`, `compiler-ir-instr-map` and related operand helpers instead of copying full-variant walkers. |
| Target predicates | [target cfg builder](../src/compiler_target_cfg_core.tl) | Use the shared target presets and [target dispatch guard](../scripts/check-codegen-target-dispatch.sh). |
| ELF relocatable input syntax | [ELF reader](../src/linker_elf_object_reader.tl) | Preserve the input/content owner, physical IDs and borrowed spans under the [input contract](compiler-invariants.md#elf-relocatable-object-input); #7101 owns admission and linking policy. |

Optimizer, backend, driver/CLI and LSP implementations consume shared IR; its
supporting import closure must not depend back on them. AST, intern/identity
and explicit standard-library support remain legitimate dependencies. The
[core IR dependency decision](../docs/compiler-core-ir-dependencies.md)
defines this first enforced boundary and its exact configuration scope.

## Ownership and existing contracts

[Compiler state and facts](../docs/compiler-state-and-facts.md) records the
ownership, lifetime and invalidation rules for pooled nodes, intern identities
and reusable facts. Job-state isolation remains an ongoing migration in
[#5754](https://github.com/JoNil-Botta/typelisp/issues/5754) and
[#5756](https://github.com/JoNil-Botta/typelisp/issues/5756). Serial compatibility
adapters do not make an ambient owner safe for a value from another job.

The [detailed invariants](../docs/compiler-invariants.md) retain the stage-specific
contracts, canonical APIs and regression witnesses. The
[executable template registry](../docs/compiler-x64-executable-templates.md)
covers handwritten runtime/startup/direct-object code; shared machine-program
work belongs to [#7055](https://github.com/JoNil-Botta/typelisp/issues/7055) and
[#7056](https://github.com/JoNil-Botta/typelisp/issues/7056).

The target boundary guard from
[#5347](https://github.com/JoNil-Botta/typelisp/issues/5347) is implemented.
[IR observability checks](../scripts/verify-ir-observability.sh) protect existing
contracts; [#7274](https://github.com/JoNil-Botta/typelisp/issues/7274) tracks the
broader pass/analysis safety contracts. Shared checked tooling facts remain the
migration in [#7110](https://github.com/JoNil-Botta/typelisp/issues/7110).
Extend these authorities instead of introducing parallel registries.

## Arena runtime interface

Arena handles identify roots; physical growth segments resolve their root
through word 40. The platform runtime leaves maintain this segment layout:

| Offset | Field |
| --- | --- |
| 0 | Previous physical segment |
| 8 | Data start |
| 16 | Allocation bump |
| 24 | Reservation end |
| 32 | Retired segment chain |
| 40 | Stable root |
| 48 | Flags, including atomic allocation bit 1 |
| 56 | Current physical segment, on roots |
| 64 | Linux root creator; Windows committed end |
| 72 | Windows root creator |

Dynamic segment data starts at 72 bytes on Linux and 80 on Windows. Only roots
need a creator tag. Linux records FS:0; Windows records GS:0x30. The private
static aggregate root is atomic, so its legacy static-page layout needs no tag.
The null-arena sentinel is also recognized before accessing a creator field.

`tl_arena_growth_target(owner)` accepts zero or a live root. It returns an
atomic owner, an owner created by the calling thread, or the calling thread's
independent default root. Zero selects that default root. The fallback never
uses an ambient first-class arena and does not change the current arena. It
creates a root lazily through the ordinary root constructor, including debug
registration. Reserving an empty arena consumes no profiled payload bytes.
The unsafe stdlib extern is the prerequisite consumed next by owner-aware
container growth in [#8703](https://github.com/JoNil-Botta/typelisp/issues/8703).

Linux stores the default root in `tl_root_arena` TLS alongside
`tl_current_arena`. Windows GS:0x28 points to a private per-thread cell: current
arena at offset 0 and default root at offset 8. Main and native worker entry
initialize this cell before allocation. Restoring the null-arena sentinel
allows the next allocation to resume the cached default root. Reset-all and
destruction clear that cache only when they unmap its root; reclaiming another
arena preserves it. See the [thread and lifetime invariant](compiler-invariants.md#arena-growth-targets).

## Evolving the design

Any worker may improve the design with evidence in its claimed task. There is
no permanent architecture owner or separate design approval. Update the
canonical implementation, every affected consumer, the relevant decisions and
executable checks together. Remove superseded paths, or name their remaining
consumers and the necessary condition for retirement.

A consequential decision records the invariant, authority, lifetime/invalidation
contract, tradeoff, validation and conditions for revisiting it. Explicitly
supersede obsolete decisions and remove contradictory current guidance. SPEC
and executable evidence take precedence over historical prose. Do not change
a rule to conceal a violation, weaken coverage or waive an unexplained
regression; cosmetic refactors do not need new decision records.

Validate semantics and resource effects through [src/TESTING.md](../src/TESTING.md)
and [required CI](../scripts/ci-verify.sh). The [performance protocol](../perf/README.md)
uses compiler and generated-code measurements. Keep disposable evidence under
`target/exp/<name>/`; measure added guard cost against the full CI budget.

## CLI

See the [command-line reference](../docs/compiler-invariants.md#cli), or run
`typelisp <command> --help` for current options.
