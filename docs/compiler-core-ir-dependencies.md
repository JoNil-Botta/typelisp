# Core IR dependencies

Status: required boundary introduced by
[#7774](https://github.com/JoNil-Botta/typelisp/issues/7774).

## Invariant and authority

[compiler_ir_types.tl](../src/compiler_ir_types.tl) defines shared compiler IR.
Its supporting import closure may use AST, intern/identity and explicitly
classified standard-library support. It must not depend back on optimizer
implementation, backend emission, driver/CLI or LSP modules. Those consumers
depend on the representation.

The canonical loader, resolver and macro expansion define actual dependencies.
Import spelling alone does not prove the destination. Aliases, generated
modules and `cfg` applicability must be resolved; unresolved, ambiguous or
unclassified supported edges fail instead of disappearing from the closure.

## Rationale and evolution

Independent shared IR lets validation, optimization and emission use one model
without its definition depending on an entire compiler invocation. AST and
identity dependencies reflect the current type/symbol representation. Removing
them without a demonstrated replacement would be a separate migration. A
directory exemption would allow new reverse edges to expand the boundary silently.

Revisit this boundary when a concrete shared fact needs a different canonical
home. Move the implementation and consumers together, update this decision and
policy with evidence, and retain semantic/resource checks. Do not classify
optimizer or backend implementation as support merely to pass the guard. The
finer target and pass contracts remain linked from the
[architecture entry point](../docs/compiler-architecture.md).

## Enforcement and validation

Run [verify-core-ir-dependencies.sh](../scripts/verify-core-ir-dependencies.sh)
with `TYPELISP_BIN` naming a freshly built compiler. The required gate
`stage2-core-ir-dependency-boundary` in [ci-gates.tsv](../scripts/ci-gates.tsv)
depends on the converged bootstrap producer. The existing coverage graph and
reachability validation protect this invocation; preserve all other gates.

The native [inspector](../tools/compiler-dependency-boundary/inspect.tl) uses
the canonical driver loader and public typecheck pipeline, including generated
declaration normalization, expansion and namespace validation. Each job is an
isolated process. It selects the existing eager import mode
(`TYPELISP_LAZY_IMPORTS=0`) so unused qualified imports cannot hide transitive
edges. A failure to select that mode fails the check.

An inspector built with `compiler-dependency-audit` streams JSON source facts
when the loader records a surface summary, while its owner is alive. The
parser emits predicate names as it evaluates them, including generated cfgs.
Only successful complete frontend processing emits the terminal fact. No
summary is retained after its owner retires. Default builds omit the imports
and tracing calls. This gate is the named consumer of the diagnostic cfg;
remove the cfg, emitter and hooks if this consumer is retired or replaced.

The [coordinator](../tools/compiler-dependency-boundary/boundary_core.tl)
checks an explicit [path/role/reason policy](../tools/compiler-dependency-boundary/policy.json).
Every reached source must be classified. Missing paths, duplicates, unknown
roles, forbidden dependencies and unreachable core/support records fail.
New or renamed files cannot fall outside discovery silently. Policy owns
classification only; it is not another parser, resolver or semantic checker.

The supported configuration space is the coherent Linux and Windows presets
from the [shared target cfg builder](../src/compiler_target_cfg_core.tl), with
every Boolean assignment of discovered non-target predicates. Arbitrary user
overrides that enable another target's aliases are outside this first slice;
the guard does not claim coverage for contradictory target configurations.
[#9126](https://github.com/JoNil-Botta/typelisp/issues/9126) tracks rejecting
those overrides in the canonical target builder and retiring this caveat.
Target-exclusive alias fixtures prevent accidentally combining the presets.
New non-target names append stable bit positions; earlier jobs already covered
the new bits as false, so discovery extends enumeration without restarting it.
This covers nested and computed predicates without guessing from source text.

More than 4,096 target/configuration jobs or 8 MiB of facts from one job fails
with a work-limit diagnostic. The wrapper caps the whole process tree and
elapsed time with the repository's bounded runner. Reports stay with generated
tools under `target/exp/core-ir-dependency-boundary/`. The work limits bound the
check; exceeding one requires investigation, never silently omitted coverage.

Source fixtures cover allowed aliases/cycles, direct and indirect forbidden
edges, unused imports, generated imports, discovered predicates, unresolved
and ambiguous imports, renamed modules and stale policy. Synthetic inspector
fixtures reject malformed, incomplete and unterminated fact streams. Both run
the same coordinator as the real check. Preserve these witnesses and measure
the complete guard's runtime/memory when changing discovery or orchestration;
account for added required CI cost against
[#6881](https://github.com/JoNil-Botta/typelisp/issues/6881).
