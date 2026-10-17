# Finite ownership model

`main.tl` is an independent executable model for the initialization/move and
control-flow portion of [the ownership core](../../docs/ownership-ir.md).
It imports only `stdlib.io` and `stdlib.test`. Neither its concrete interpreter
nor its expected results call the production checker. Production comparisons
must live in a separate adapter that imports this model, rather than introducing
a compiler import into the oracle.

The model represents two distinct bindings. The first has the shape
`root = (head, tail = (left, right))`; the second is `shadow`. Its names are
explanatory: the six place constructors are identities, so initializing the
shadow cannot restore a moved outer leaf. Four Boolean leaf fields give sixteen
concrete initialized/uninitialized stores. Concrete reads inspect the fields
selected by the projection tree, moves require those fields and clear them,
initialization sets them, and invalidation clears them without reading.
These are the initialized-before-use, partial move, exact reinitialization,
shadowing and diverging-arm rules of SPEC sections 1 and 4.7.2.

The separately implemented abstract domain uses definite/possible initialized
leaf masks and an unreachable bottom. There are `3^4 + 1 = 82` elements. Join
intersects definite masks and unions possible masks; unreachable paths contribute
nothing. A read or move fails if a selected leaf is not definitely initialized.
Abstract transfer keeps a conservative successor after failure; a sticky failure
flag prevents that successor from becoming an acceptance certificate.

The runnable checks cover:

- All 82 domain elements and all 551,368 triples for join identity,
  idempotence, commutativity, associativity, upper-bound and least-upper-bound
  laws.
- All 24 operation/place pairs on all abstract states and all concrete members:
  successful concrete successors are contained, and abstract rejection is exact
  for this finite domain. All ordered abstract-state pairs check transfer
  monotonicity, including its failure bit.
- 460,800 graphs: all sixteen entry stores, two arms independently selected from
  24 operations and five exit kinds, and a retained cleanup read of `Tail`
  either present or absent. A nondeterministic loop header permits zero trips
  and either arm on every subsequent iteration. Fallthrough and continue reach
  the header; break reaches the normal exit; return and abort remain distinct
  terminal outcomes. Cleanup runs on scope-leaving edges except terminal abort.
  The graph models an owner retained across the loop, not a newly initialized
  owner on each iteration.
- Authored witnesses for a nested partial move, disjoint sibling use, shadowing,
  reinitialization, returning arms, loop backedges, break joins, cleanup on
  return, and abort without cleanup. Oracle controls distinguish deliberately
  wrong answers for lost move state, an incorrectly definite join, an omitted
  cleanup use and a dropped backedge. All sixteen concrete identity encodings
  round-trip. Actual source mutation coverage is described below.

The concrete graph interpreter enumerates its entire reachable finite state
set, including arbitrarily repeated loop iterations. The abstract interpreter
independently reaches a fixed point over cubes. Both have a 32-round resource
limit; a result that does not reach a fixed point is incomplete and fails the
comparison. A zero-budget witness exercises this rule. The graph campaign
requires its exact expected case count. A counterexample prints its initial
state, operation/exit codes and both outcomes; it is never filtered out.
For graph counterexamples, `first = 2 * initial-store + cleanup-present`,
`second` and `third` encode `24 * exit + 6 * operation + place`. Exit order is
fallthrough, continue, break, return, abort; operation order is read, move,
initialize, invalidate; place order is root, head, tail, left, right, shadow.
Concrete store bits are head, left, right and shadow from least significant
to most significant.

Run the five inline tests with the repository compiler:

```sh
target/stage0/typelisp test tools/ownership-model/main.tl
```

The canonical `scripts/verify-inline-tests.sh` discovers them under `tools/` on
both hosts. For an executable with a stable summary line, build into the
disposable experiment directory:

```sh
mkdir -p target/exp/ownership-model
target/stage0/typelisp build tools/ownership-model/main.tl --opt-level 1 \
  -o target/exp/ownership-model/model
target/exp/ownership-model/model
```

A complete run exits zero and reports
`ownership-model-v1: lattice=82 concrete=16 places=6 operations=4 graphs=460800 passed`.
Any counterexample exits nonzero. Run at optimization levels 0, 1 and 2 when
changing the model; agreement alone is insufficient, since every run must also
satisfy the independently specified concrete oracle and authored witnesses.

`crosscheck.tl` is the separate production adapter. It constructs a typed core
body whose six places correspond to the model's tree, plus an initialized
Boolean condition. Its 2,916 transfer comparisons cover all 81 reachable
abstract cubes, 24 operation/place choices, and twelve ordered disjoint scalar
source/destination pairs for explicit `Move`. The latter derives its result
from a concrete model move followed by destination initialization. Expected
rejection and successor readability
come from running `model-step` on every concrete member, including all sixteen
singleton stores. Product parent nodes are checked alongside leaves. Its
28,800 CFG comparisons cover both 120-arm choices, including all five exit
kinds, and both cleanup modes from a fully initialized entry. The normal exit
also reads `Root` to observe diamond, loop and break joins. Expected results
come from the concrete graph interpreter; the model's abstract transfer is
not the production oracle. Unexpected structural, unsupported or resource
errors fail the comparison instead of counting as semantic rejection.
Every reported rejection must also identify a block, instruction, place and
source line with an independently reachable concrete failure witness.

Run the production adapter with a compiler built from this checkout and the
compiler source import root. Set `TYPELISP_BIN` to that compiler; the published
seed used during this implementation still exhibited the borrowed enum
descriptor defect and correctly failed these comparisons.

```sh
"$TYPELISP_BIN" run tools/ownership-model/crosscheck.tl \
  --stdlib-root stdlib --stdlib-root src
```

The adapter carries no inline tests: package builds preflight every source
with inline tests, and its compiler imports resolve only with the `src`
import root, so an inline test here would break the root package build. Its
`main` runs the same two comparisons, which the gate below exercises.
The native opt0/1/2 campaign for these programs and the mutation witness driver is:

```sh
TYPELISP_BIN="$TYPELISP_BIN" scripts/verify-ownership-model.sh
```

The wrapper requires all thirty-nine runs, exact complete summary lines, zero exit
status and empty child stderr. Each build has a 1 GiB process-tree cap and each
run a 256 MiB cap; every child has a 120-second timeout. Missing enforcement or
resource reports fail the run. Compiler and source digests, the source commit,
source copies, captured streams and resource reports are kept under
`target/exp/ownership-model-verify`. Input digests must remain unchanged through
the campaign. The digest inventory includes all stdlib `.tl` files as a
conservative superset of transitive imports and prelude macros, including dirty
dependencies; unrelated compiler modules are excluded. Set
`TYPELISP_OWNERSHIP_MODEL_WORKDIR` to choose another artifact
directory. This wrapper runs on both repository CI host families; unsupported
hosts fail explicitly.

The same wrapper also builds three isolated copies of the production core at
opt1: one retains the source state after `Consume`, one retains it after
`Move`, and one drops later incoming states only at the solver's CFG merge.
The latter preserves first-predecessor initialization and the ordinary parent
summary operation. Its witness is a real loop graph: a path moves the whole
root, whose uninitialized state must reach the next header and normal exit.
Each selected edit must match exactly one source site. Compilation must succeed, and the resulting
crosschecker must then exit normally with status 1, empty stderr and the exact
independently specified mismatch. Crashes, parse/type failures, unrelated
mismatches and unexpectedly successful runs all fail the mutation campaign.
`mutations.tsv` records each obligation and witness; the mutated sources,
digests, streams and resource reports are archived alongside the baseline
runs. The original compiler and production source digests must remain
unchanged.

Four further isolated builds actually modify the abstract model implementation:
retain definite initialization after a move, union definitely initialized join
bits, omit the cleanup read, and drop the loop backedge. They leave the concrete
interpreter and `mutation_witness.tl` unchanged. That driver requires the exact
post-move state (13/13), joined state (13/15), failed cleanup after a partial
move, and failed use on a later loop iteration. Each mutant must compile and
then exit normally with its exact named mismatch and empty stderr. Together
the initialization programs contribute nine positive runs and seven mutations.
The loan programs below contribute another fifteen runs and twenty-five mutations.
The cleanup programs contribute twelve runs and sixteen mutations, and the
allocation program three runs and five mutations.
The whole campaign requires 184 enforced build/run reports: 39 positive runs,
31 production mutants and 22 model mutants, each with a separate build and run.
These checks do not cover application runtime obligations.

## Concrete loan executions

`loan_model.tl` independently interprets concrete executions over two memory
cells and three capability slots. Every issuance creates a fresh dynamic token;
children retain their actual parent's generation. A shared loan issued again
while its earlier token is still retained (a loop's borrow site whose old token
a child keeps) joins that token: two shared tokens of one loan have the same
cell, authority and parent generation, so one slot token stands for both and
lives while either is needed. An exclusive loan issued again then fails, since
the two would alias. Ending a joined token ends both issues, so the model
rejects ending the new issue while only the old one is still needed; production
rejects that trace too, and the normalizer emits no EndLoan. It scans the remaining
concrete trace for uses of that token, including uses through descendants, to
decide expiry. It does not implement the production backward CFG algorithm or
call a production transfer. A trace is limited to 128 events; invalid identities
or parent relationships produce an explicit invalid-input outcome.

`loan_main.tl` checks all 576 combinations of initial memory, shared/exclusive
authority, borrowed/accessed cell, direct operation and later retention against
a separate truth table. Thirteen authored controls cover reborrows, disjoint
access, explicit ending, repeated issuance, old-child retention across the
reissue of an exclusive parent (rejected) and of a shared parent (joined, and a
write under the joined token conflicts), and invalid access. Its exact success
line is
`ownership-loan-model-v2: direct=576 reborrow=13 three=8 holders=16 limits=3 passed`.

Eight additional authored controls exercise competing direct loans, overlapping
and expired siblings, disjoint exclusive loans, retention through two ancestors,
and through-access exemptions through the whole granting chain.

`loan_crosscheck.tl` is the separate production adapter. It compares those 576
direct cases, 137 reborrow cases, and 3,848 three-loan cases against the concrete
interpreter. The latter include the eight authored controls and all 60
structurally valid direct/sibling/chain configurations, eight retention masks
and eight subsequent accesses. Shared input construction lives in
`loan_cases.tl`; it contains no expected decisions or transfer semantics.
Seventeen authored CFGs cover diamonds, joins, branch-local expiry, early
returns, ending across backedges, old children across exclusive- and
shared-parent reissue, and references that may hold either branch's loan. The
adapter enumerates 54 concrete paths, including zero through three loop
iterations, and never filters a rejected path. These bounded loop executions
are evidence for the authored graphs, not an exhaustive argument about all
loops. Success is exactly
`ownership-loan-crosscheck-v1: direct=576 reborrow=137 three=3848 graphs=17 paths=54 passed`.

The original `Event` traces name static loan slots with Keep and MayKeep.
`ReferenceProgram` additionally interprets three reference holders whose values
retain the exact issued token, over the same two cells and three loan sites.
Bind, Copy, Move, Clear and Use execute concrete value transfers; Copy requires
the shared reference type, and moving an exclusive reference clears its source.
Expiry follows actual values along one concrete suffix, independently of the
production backward holder-demand analysis. Existing primitive transfers and
generation/parent checks remain shared within the independent model. Programs
are limited to 128 events with one shared or exclusive type for all holders.
Sixteen controls cover overwrites, surviving copies, moves, self-moves, shared
and exclusive reissues, explicit ending with an older reference still used,
unavailable references and malformed holder/type metadata. Three more controls
reject negative/excessive loan counts and an over-limit trace before indexing.

The production adapters still use the original trace representation. Their
reference-value correspondence, CFG/path expansion and targeted mutations
remain incomplete; the new concrete controls alone do not establish production
soundness. The production rules remain witnessed by the core cases
`ownership-loan-holder-overwrite` and `ownership-loan-reissue` and by the
safety fixtures `mir_nll_loop_if_join_reference_*`,
`mir_reference_copy_then_write_reject`,
`mir_reference_holder_move_then_write_reject` and
`mir_reference_loop_reissue_*`.

The independent interpreter exposes concrete generation tokens before and after
each executed event. Linear comparisons check exact loan-state masks on every
valid prefix, distinguishing never-issued from expired capabilities by actual
issuance history. CFG comparisons require every concretely retained generation
to occur in the production possible-active set. A definitely-active capability
at a demanded use must exist on every enumerated path reaching that use.
Static liveness may retain additional capabilities because a different branch
uses them; the adapter does not incorrectly equate it with one trace's expiry.
Every concrete failing CFG path must also find a Loan failure recorded at its
own failing point. A matching first error on a different path is insufficient.
Production inspection uses the same checks/effects as ordinary checking, keeps
errors sticky, and reports incomplete resource/structural runs explicitly.

Malformed parent permissions and malformed through-accesses are checked as
structural failures with their exact metadata or operation location and message.
They remain in the case count rather than being discarded. Only well-formed
bodies participate in the dynamic first-failure and per-point comparisons.
Path conversion checks entry, adjacency, terminal exits and its supported
Boolean-branch/empty-return schema; unsupported place indices cannot alias the
model's right cell.

Eleven isolated production mutations remove parent retention, allow shared writes,
discard ending-loan demand, drop a join predecessor, omit a branch successor or
omit backward edges. Each must genuinely compile and then fail with its
independently predicted semantic witness; positive expiry controls also detect
overly restrictive loan lifetimes. Further mutations remove issuance conflicts,
truncate ancestor retention or grant exemptions, discard descendants at parent
definitions, or admit re-issuing a still-retained parent.
Six actual concrete-model mutations remove shared-write permission, parent
retention, ending-loan demand, expiry, issuance conflicts or transitive retention.
`loan_mutation_witness.tl` independently requires the correct rejection event
or the successful post-expiry write. Compiler crashes, unrelated rejections,
resource exhaustion and malformed output never satisfy a mutation check.

`loan_laws.tl` independently represents status sets by explicit membership in
Unissued, Active and Ended. It compares the production join to set union on all
eight scalar sets and all 512 three-component states, checks join laws and
monotonicity, and checks expiry and direct shared-loan transfer against concrete
members. Its exact counts are 64 scalar pairs, 512 scalar triples, 262,144
product pairs, 4,096 expiry cases, 3,087 transfers, 15,552 concrete member
comparisons and 61,731 ordered transfer comparisons. This factorized domain
check covers no parent-generation or alias relation; those belong to the trace
campaign. Three further production mutants break join, expiry and issuance.

`loan_value_crosscheck.tl` compares 1,160 value-operation cases, twenty Boolean
branch cases, twelve return cases and ten authored valid/invalid controls to
the concrete loan interpreter. Copy and Copy-typed Move read the source and
write the destination; non-Copy Move consumes the source; Copy Consume reads
without ending ownership. Retention occurs after the complete core operation.
Successful transfers also check both leaf initialization states and their
product summary. The exact summary is
`ownership-loan-value-crosscheck-v1: values=1160 branch=20 return=12 controls=10 passed`.
Five production mutations weaken Copy destination permission, incorrectly
require exclusive authority for Copy Consume, weaken non-Copy Move source
permission, omit branch loan access, or omit the returned-value initialization
check. Each has a distinct, independently derived mismatch witness.

## Concrete cleanup executions

`cleanup_model.tl` is a separate, compiler-independent interpreter over two
two-field resource slots. Fresh dynamic tokens and an explicit cleanup log
check exact-once behavior and reverse field/binding order. It distinguishes
automatic required cleanup from a manual discharge obligation, whole and
partial transfers, reinitialization, explicit cleanup, escaping returns,
terminal abort and abort during cleanup. `cleanup_main.tl` checks 192
whole-owner truth-table cases, 18 authored controls, 30 construction/scope
controls and two exact trace-boundary cases; the summary is
`ownership-cleanup-model-v2: direct=192 controls=18 construction=30 bounds=2 passed`.

Construction is an explicit frame that acquires resources without activating
automatic cleanup. `BindComplete` requires a complete value and activates the
binding. A normal exit from construction must have transferred or cleaned
every acquired field; it does not invent an implicit partial destructor.
Binding order follows an actual stack, independently of numeric owner names.
Reinitialization preserves that position. A partially moved manual owner may
be restored and then cleaned as a whole; unresolved partial discharge still
rejects on a normal exit. Abort retains the specified no-unwind behavior.
Each cleanup action records its event, owner, field and dynamic token.
`cleanup_cases.tl` shares inputs only; expected decisions and order remain in
the separate interpreter and truth table.

`cleanup_crosscheck.tl` translates inputs into production bodies without deciding
resource validity. It compares acceptance, exact first rejection location and
the complete static cleanup action sequence to the independent token interpreter.
Checking and inspection must report the same result. Each input is repeated
with unchanged, reversed and rotated obligation IDs; `cleanup_rename.tl`
validates a bijection and remaps the table, parents and operation references.
The 576 direct and 90 authored comparisons include leave/reentry with an inactive
obligation between two live frames, partial construction, restored manual
owners and live-field overwrites. They cover standalone core semantics; source
normalization still needs its own migration evidence.

`cleanup_cfg_crosscheck.tl` compares five graphs and sixteen concrete paths,
including zero through three loop iterations. Conversion validates every edge
and resource operation. Accepted paths check exact action order; every rejected
path must have its own per-point failure bit, even when another path supplied
the first diagnostic. Nine production mutations break required automatic use,
manual discharge, partial discharge, construction responsibility, activation,
field order, loop edges, later-path failure evidence or numeric-ID unwind order. All must compile and
fail normally with their independently specified mismatch.

Seven independent-model source mutants break required scope-exit
use, reverse field order, actual binding order, live-slot overwrite rejection,
partial-discharge rejection, construction responsibility or the distinction
between construction and binding activation. Their fixed witness driver must
fail normally with the named reason.

This is bounded executable evidence, not a machine-checked soundness proof.
The initialization model does not model loans; the concrete loan model covers
only the finite capability operations described above. Neither covers arenas,
indirect calls, closure captures, variant
selection, dynamic indices, runtime allocation, SPMD or concurrency. The six
fixed places and four leaves are a deliberate finite bound, not a policy for
rejecting supported source programs. Passing this model alone says nothing
about whether a compiler entry point runs the ownership analysis or whether
lowering and execution preserve its conclusions.
# Allocation lifetimes and sanitizer limits

`allocation_model.tl` is an independent concrete allocation model. A pointer
retains an owner, owner generation, allocation serial and offset; acceptance
also requires the allocation's live time interval and the complete access
extent. Numeric address equality never restores a retired pointer's authority.
The model imports no compiler or runtime implementation.

The 672 lifetime cases enumerate four allocation sizes, seven offsets, three
access widths and eight times. Each case checks the original allocation,
rewind followed by same-address allocation, owner retirement followed by
same-address reuse, and an independent live owner. Expected byte bounds are
computed by enumerating the addressed bytes, independently of the model's
subtraction-based guard. Twelve controls cover boundaries, identities and
near-maximum integer inputs. The 1,224 page cases enumerate page sizes 1–8,
marks across two pages, and reads across three pages. They establish that
protecting whole retired pages preserves the live prefix, and explicitly find
retired bytes that share a readable page with live data.

`verify-ownership-model.sh` runs this model at opt0/1/2 and requires five isolated
guard-removal mutations (owner, generation, allocation serial, retirement and
extent) to fail normally. This does not cross-check a production arena borrow
analysis. It describes obligations that page protection cannot establish:
suballocation bounds, pointer provenance, and partial-page stale accesses.
Poison is not a universal oracle either: a stale program can expect `0xA5`.
