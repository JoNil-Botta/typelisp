# Compiler state and reusable facts

Status: current contract; migration from serial compatibility state continues
in [#5754](https://github.com/JoNil-Botta/typelisp/issues/5754) and
[#5756](https://github.com/JoNil-Botta/typelisp/issues/5756).

## Invariant and authority

An AST node ID belongs to its `AstNodePoolContext`; it is not a process-wide
identity. Source-name and structural intern handles likewise belong to their
compiler session. Copying a wrapper, ID or shallow view does not change its
owner or extend its lifetime. Equal numeric IDs from different owners do not
establish equality.

[compiler_ast_types.tl](../src/compiler_ast_types.tl) owns node representation,
pool access and source-view traversal. [compiler_intern.tl](../src/compiler_intern.tl)
and [compiler_intern_state.tl](../src/compiler_intern_state.tl) own interned
identities and sessions. [compiler_driver_core.tl](../src/compiler_driver_core.tl)
owns job setup, pool retirement and cache cleanup;
[compiler_typecheck_core.tl](../src/compiler_typecheck_core.tl) owns `TcContext`
and its expression/fact accessors.

Consumers with a context use its owner-aware accessors. Pure classification may
use canonical unspanning with that owner's segment bases; diagnostics and memo
keys must additionally preserve their source/macro or identity contract.
Do not erase wrappers indiscriminately. Cached segment-base views remain valid
only within the pool lifetime guaranteed by their caller.

Borrow-conflict read normalization carries the source expression ID with its
pool owner. It changes `BoxTake` to `BoxGet` only along value-producing paths;
conditions, initializers, scrutinees, indices and sequence prefixes retain
their ordinary access. An unchanged path keeps its original ID and argument
list without allocating replacement payloads. Changed paths use the canonical
AST child schema and allocate new
payloads in the source pool's owner arena. Shared source occurrences and their
provenance remain unchanged even when another pool or arena is current.

A reusable fact identifies its semantic inputs and stays within their lifetime,
or copies into the destination owner through the canonical API. Invalidate
dependent facts before reusing changed inputs or retiring their pools. Choose
an arena by the longest boundary the state must cross, following the
[compiler arena contract](../src/TESTING.md#compiler-arena-ownership).
Serial adapters serve explicit compatibility paths; propagate an available
job owner instead of introducing another ambient-state dependency.

The loader's `CompilerLoadSurfaceSummary` describes parsed declarations and
imports. Disabled `cfg` branches and unexpanded generated imports mean it
cannot certify a complete semantic dependency graph. Reuse the canonical
loader/resolver and expansion stages for their respective facts. The
[core IR guard](../docs/compiler-core-ir-dependencies.md) streams source paths
while summaries are alive, then requires successful canonical frontend completion.

## Rationale and evolution

Explicit owners permit independent jobs and prevent ambient state from
reinterpreting IDs. Cloning every aggregate hides the ownership problem and
increases arena cost; swapping a global pool around each helper preserves
hidden coupling. Prefer existing owner-aware APIs and measured narrow views.
Add no unsafe view when an existing borrow suffices.

Revisit representation or retention when evidence demonstrates a simpler safe
lifetime or a concrete resource problem. Migrate callers and cache keys
together, keep minimized cross-owner reproducers, and explicitly retire old
adapters when their remaining consumers are gone. Stage-specific contracts
remain in the [detailed guide](../docs/compiler-invariants.md).

## Validation

Follow [src/TESTING.md](../src/TESTING.md). Extend the owner-isolation tests in
[compiler_typecheck_core.tl](../src/compiler_typecheck_core.tl) and
[compiler_driver_state_smoke.tl](../src/tests/compiler_driver_state_smoke.tl)
with independently allocated pools, colliding IDs and changes to the installed
compatibility pool. Cover source/macro diagnostics and cache reuse as well as
successful compilation. Run the fresh compiler's affected tests, bootstrap
fixpoints and required CI; measure allocations/instructions for hot accessors.
