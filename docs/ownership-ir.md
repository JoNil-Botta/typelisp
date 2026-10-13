# Ownership IR: semantics and migration inventory

This document records the foundation for [#8449](https://github.com/JoNil-Botta/typelisp/issues/8449)
and its production cutover. Every named function body and every module
value's initializer is now checked by the ownership graph: the selected
producer publishes typed occurrences (`src/compiler_typecheck_core.tl`), the
normalizer builds the ownership body (`src/compiler_ownership_normalize.tl`)
and the core checks initialization, moves, loans, cleanup obligations and
arena invalidation (`src/compiler_ownership_core.tl`). The legacy AST move and
borrow walkers are deleted; there is no unchecked fallback (see
[Production cutover](#production-cutover-m5)). The independent bounded model
lives under `tools/ownership-model/`. Lowering still emits IR from the AST of
a certified body; MIR-to-IR checked lowering, the remaining M3/M4 validation
and the items under the cutover's known limits are open. Later sections also
record the design and inventory as each slice landed; where one of them says a
part is not yet implemented, the cutover section and the code take precedence.

## Production cutover (M5)

**One authority.** A body is accepted only when the producer represents it
and the core certifies it. A body the producer cannot represent, or one the
normalizer cannot certify (`Unsupported`, or `Resource` past its fixed record,
work, depth or provenance bounds), is rejected with E0211 "the ownership
checker does not support a construct in this function body" and the reason as
help (`tc-selected-unsupported-body-error`). Typing (types, lifetimes named in
signatures, region flow into returns) still runs before the graph; it is a
type check, not a second ownership verdict.

**Coverage evidence.** Every tracked `.tl` file and every program embedded
in the compiler's test sources (string literals holding `(define (`) is
checked; none fails closed except `tests/safety/mir_resource_limit_reject.tl`
(a 4,200-operand `and`), and none that the last pre-cutover compiler accepted
is rejected outside the documented soundness fixes below. The selected
producer has no well-typed source form left that it leaves unrepresented.

**Reverse coverage.** The other direction is checked too: every program main's
compiler (e10dcb268) rejects among main's and this branch's tracked `.tl` files
and the programs embedded in either side's compiler tests (6,111 programs,
2,916 rejected by main) stays rejected here, except programs a precision
change below accepts as Rust does (dead borrows, a Copy-only match, code after
`return`, a non-Copy part moved out of a Box) and files only one side can
load. The corpus never exercised the holes the third review found (below):
each now has a fixture, and every place form `deref` reaches is pinned by
`tests/integration/deref_place_forms.tl`.

**Forms added for the cutover** (builtin codes in the typed store): 152 the
owned element of a `for` over a fixed array, 153 fresh data (embedded bytes,
the environment pointer, a runtime `quote`), 154 a literal index into an array
or tuple literal (only the selected element's loans flow out), 155 a runtime
quasiquote over its unquoted `Expr` and spliced `ExprList` operands. C
variadic extern calls are checked against their signature expanded to the
call's arity. `RequireUnheld` (typed operation; normalizer exits 9/10) checks
that a `with` cleanup owner allocated in an arena no longer holds that arena's
values when the arena is destroyed or rewound.

**Soundness fixes over the legacy checker** (each with a `tests/safety` row):
moving an owner out of an element read through a borrowed array (the
`stdlib/queue.tl` deque now clones; `net/http_types.tl` moves with
`replace!`); a struct or enum without `(:lifetimes ...)` may not hold a
reference (its type names no lifetime, so a value could outlive its referent);
writing a place while a value holding its loan is live.

**Removed.** The legacy `tc-move-*`/`tc-borrow-*`/`tc-moved-*` walkers (about
18,000 lines), the legacy lambda capability walk, and the disabled checked
lowering route (`compiler_ownership_lower.tl`, the source witness and the
retained normalized bodies); the certificate handoff remains: lowering
requires every body's certificate and emits it from the AST.

**Known limits.** Origins are field-insensitive per root, and flow-insensitive
apart from the reaching-definition split of reassigned reference bindings and
the holder kills in loan liveness (below): a read can demand every loan its
root may ever hold, and a holder overwritten only through a field write or a
reference keeps its demands. A dereference or reborrow of a reference joined
from several loans is not represented and is rejected with E0211, never
trusted, and so is `replace!` behind an opaque referent. A read through a
reference that may point to several places sees the loans of all of them, so
writing a place only one of them borrows can be rejected while another is
read (main rejects that too; Rust accepts it). A raw address
(`ptr-addr-of`, unsafe) stays outside the graph: unlike main's walkers and
Rust (E0382), taking the address of a moved place is not rejected, and
reading through that address is undefined in the unsafe block. Returned
borrows of by-value parameters and implicit `f32` to `f64` widening, open
before the cutover, are now rejected (table below).

## Implemented core boundary

`OwnershipBody` contains caller-owned type, local, place, loan, cleanup-contract,
obligation and block arrays. `OwnershipBodyId` carries owner, generation and
revision; typed local/type/place/block/loan/cleanup/obligation handles pair it
with an ordinal. Validation checks exact identity and
bounds. This API does not yet mint globally fresh owners or produce a retained
lowering admission certificate. Its caller must keep the complete immutable
body and copied source paths alive during validation and solving.

The admitted types are Scalar, Boolean and finite Product, with a Copy flag.
Places are Root or Field; product field types precede the product type and
projection parents precede children. The validator requires one root per local
and every product field exactly once, rejecting duplicate places, inconsistent
types, foreign identities, missing source locations and unsupported operations.
Boolean types must be Copy, and a Copy product cannot contain MoveOnly fields.

Operations are Read, Initialize, Assign, RequireEmpty, Consume, Copy, Move and
Invalidate. Initialize requires every destination leaf definitely empty; Assign
sets ordinary storage initialized even when it previously held a value.
RequireEmpty checks that no destination leaf may contain a value. Invalidate
clears the selected subtree; Read requires the whole subtree initialized. Consume and Move remove
MoveOnly source contents; for Copy contents they preserve the source. Copy
requires a Copy type; Copy/Move destinations have the same type as the source,
and Move rejects overlapping source/destination places. Ordinary writes never
implicitly call cleanup. A possibly initialized cleanup-bearing destination
requires explicit discharge before replacement; raw consumption or invalidation
cannot erase its responsibility.

Cleanup contracts explicitly distinguish declared type ownership from a
context-only hook. Type-owned contracts require a MoveOnly type and one exact
canonical contract per type. Every root of that type needs an obligation record;
owned parameters are Unsupported in this slice. Ordinary products cannot hide
owned fields. Product cleanup plans cover every owned field under its exact
contract, and may additionally include explicit hooks on Copy fields. Those
hooks do not make every value of the Copy type an owner. Intrinsic contracts
currently admit scalar resources; source callee declarations and explicit
cleanup bindings of Copy values still need further representation.

BeginConstruction pushes an empty Building frame. Field acquisition does not
activate a lexical binding; BindComplete requires the whole value initialized
before changing the frame to Bound. BindFresh and BindMove combine complete
acquisition with binding activation. The parent metadata must extend the actual
active stack; table order is not lexical order. Simultaneously active frames
cannot alias one root. Leave pops the current frame, and CFG joins require the
same stack and phases. A Building frame has no automatic partial destructor:
a normal exit must prove it empty or explicitly clean/transfer its resources.
Abort requires no cleanup.

Bound AutomaticRequired owners retain their whole cleanup use on every normal
scope exit, even after an earlier whole move or explicit cleanup. Bound
Discharge owners must become empty through a complete transfer or cleanup.
Partial moves may be repaired before whole cleanup; moving every field
separately does not prove whole discharge. A private initialized marker in the
checked expansion preserves that distinction across CFG joins and backedges.
CleanupPlace can explicitly clean a complete field under its exact declared
contract. ReturnOwned transfers complete Discharge owners or construction
results; active AutomaticRequired owners and values with unrepresented result
dependencies cannot escape this way.

Retained cleanup operands are actual reads, including through-loan permission
and liveness uses. Transfers preserve every exact retained dependency in the
destination obligation; field transfers conservatively preserve the full set
until projection-specific origin evidence exists. Field cleanup likewise checks
all owner dependencies. This does not yet implement general reference or region
transport. A same cleanup ID or a same-typed destination alone cannot drop the
retained operands.

Checked cleanup expansion produces another canonical OwnershipBody with copied
provenance and private discharge markers, then uses the existing initialization
and loan solver. It does not add an independent admission decision. Executable
scope errors stay at their original program points, preserving an earlier
initialization or loan failure. Cleanup actions are a static, per-point schedule:
fields run in reverse declaration order with nested cleanup completed first,
and bindings leave in actual reverse activation order. Worklist revisits do not
append duplicate actions.

Loan records carry a place, shared/exclusive mode, source provenance and an
optional parent loan. Parents precede children and a child place must be inside
its parent's subtree. Each loan has exactly one static Borrow or Reborrow
definition; a single indexed census validates full definition identities before
counting them. Loops may execute that definition repeatedly. Shared writes and
exclusive children of shared parents are malformed even in unreachable blocks.
UseLoan retains a
capability without accessing its referent. AccessThrough explicitly reads or
writes a descendant place; writes require exclusive authority. Granting
ancestors permit the access, while overlapping live descendants and siblings
still restrict it. Direct reads conflict with exclusive loans; mutation,
invalidation and MoveOnly consumption conflict with every overlapping loan.
Borrow and Reborrow require initialized contents.

The checker solves backward liveness on this same body, with definition kills
at Borrow/Reborrow and ancestor retention for demanded children. A definition
kills its previous instance only when no descendant still demands that instance;
otherwise forward transfer finds the loan active at the reissue, where a shared
issue joins it and an exclusive one is rejected. Backward rows
remain ancestor-closed, including across definitions and loop backedges.
A loan defined in a block on a control-flow cycle is issued again on each
trip, while a reference may still hold an earlier trip's issue and be read
later (`prev` in `(set! prev cur)` after `cur` borrows again). For such a loan
the definition ends only its plain demands (its retention and its first uses,
each of which comes with the demand of the holder it is read through); every
holder demand ends only where its holder is overwritten whole, so the loan
stays live across the backedge exactly while such a reference may be read.
The forward walk then finds the loan active at its next definition: a shared
issue joins the held one, since both permit the same accesses, and an
exclusive issue is rejected as an alias, as Rust's E0499 rejects it
(`mir_reference_loop_reissue_held_reject` and `_shared_ok`; core cases in
`ownership-loan-reissue`). Besides a Copy or Move, the single Assign of a
temporary (a root with no other write and no exclusive loan) overwrites its
holder whole; an indexed store may assign the root it updates in place, so
another Assign never ends a demand. A borrow of a place that holds references
leaves those loans in that place: the borrow is a use of them through the
borrowed root, so a reference that is only ever reached through such a borrow
(`(& prev)`) still keeps its earlier issue live until it is overwritten
(`mir_reference_loop_reissue_borrowed_holder_reject`, `_ok`). Forward loan
cells union unissued, active and ended possibilities. Uses require definitely
active authority; conflicts consider possibly active authority. Last-use
expiry comes from the solved per-point table. EndLoan is a consuming use that
requires active authority and rejects future demand, including demand through
children across branches and loops. It is not an unchecked liveness promise.
A MayUseLoan names the root place whose value it reads (its holder), and its
demand is keyed by that holder as well as by the loan: like the liveness of
the variable a Rust reference lives in, it also ends, going backward, where a
Copy or Move overwrites the whole holder, because a later read sees the value
stored there. The transfer is itself a read of its source, so the source's
MayUseLoan operations immediately precede it, one per loan of the source's
origin: a demanded loan among them continues as that operation's demand, and a
loan missing from them cannot be in the stored value and ends. Cleanup elaboration
may insert a RequireEmpty of the destination between them, which the scan
skips. A transfer with no such operations (a source without a recorded origin,
or a Move synthesized by cleanup elaboration) carries unknown loans, so each
demand continues as the source's own demand of its loan if it has one, and
otherwise as a plain demand of its loan. A reference joined from two branches inside a loop
therefore demands a branch's loan only on paths through that branch's
assignment (`mir_nll_loop_if_join_reference_ok`), while a copy or move of a
reference keeps the loan across the transfer
(`mir_reference_copy_then_write_reject`,
`mir_reference_holder_move_then_write_reject`; core cases in
`ownership-loan-holder-overwrite`). Without that continuity the forward walk
would expire the loan at the transfer and stop checking it.
This subset has no representation for escaping loan values: UseLoan followed
by Return does not establish a result lifetime contract; typing checks the
lifetimes a signature names before the graph runs. Calls and reference
transport reach the core through the normalizer's origins and MayUseLoan
operations. Cleanup expansion inserts its
retained reads before running the same liveness analysis.

Goto and Branch form explicit CFG edges; Branch requires an initialized
Boolean place. Return reads its retained operands before that edge's checked
scope unwind. Abort has no successors or implicit cleanup behavior. Loops are graph cycles;
source `break` and `continue` would normalize to the appropriate Goto edges.

Each place's abstract cell is a possible initialization-state set: 1 means
uninitialized, 2 initialized, and 3 either. Zero is used only for unreached
input cells. Joins are bitwise union; parent states summarize child states.
Parameters start initialized and other locals uninitialized. A bounded
worklist revisits a block when its reachable input grows. Default limits are
65,536 nodes per bounded collection, 16,777,216 state cells and
67,108,864 work units; exhaustion returns a Resource failure. Structural,
unsupported, initialization, loan, cleanup and resource failures are distinct. Loan
graphs additionally bound their total instruction/terminator points and
reserve checked point/loan and block/loan products before allocating tables.
Each validation, backward and forward phase has a bounded work counter.
Cleanup expansion reserves its copied graph, scope rows, output actions and
provenance before allocation; it subtracts its work/storage reservations from
the solver's remaining allowance. Initial structural validation remains a
separate bounded phase. Diagnostic remapping reserves its extra original-point
rows and work before invoking the base inspector. Liveness iteration and permission ancestry scans fail closed on exhaustion.
Work charging includes node/state initialization and each occurrence of source
path and expansion bytes, even when those strings share storage. Validation
and diagnostic dumping therefore cannot bypass the budget through repeated
large provenance fields. Move validation reserves its ancestor walks; return
operands and unsupported diagnostic reasons are charged before traversal or
copying. The solver reserves block and terminator work before executing it.
After structural validation, initialization builds three place-index arrays
(parent, first child and next sibling) once, reserving their cells and setup
work before allocation. Subtree updates use iterative traversal and rebuild
ancestor summaries from direct children; each visited node is charged. They
do not scan unrelated places or reserve a quadratic cost per instruction.
Loan permission checks charge each inspected loan and visited parent link;
there is no per-instruction reservation of the maximum loan/place product.
The definition census is linear in loans plus graph points. Structural
duplicate-place validation still uses a bounded quadratic scan, and backward
liveness sweeps can require repeated passes on unfavorably numbered CFGs. The
node cap is a hard ceiling, not a guarantee every graph beneath it fits the
work budget.

`ownership-inspect` runs the same solver and canonical transfer effects with
optional bounded diagnostic tables. It records masks before expiry, after
expiry/before the operation, and after the operation, plus solved backward live
rows and block point offsets. A per-point bitset records every local semantic
failure, including failures hidden by an earlier error on another path. Normal `ownership-check` still stops at its first
failure. Inspection retains the first semantic failure while continuing the
syntactic effects to a fixed point; those continuations are conservative
observations of rejected graphs, never an admission certificate. Structural or
resource failure leaves `complete?` false. All extra point/loan tables and
diagnostic work are charged. Inspection unions revisits, so concrete branch-local
expiry need not equal the more conservative CFG liveness at a point.

`ownership-cleanup-inspect` exposes the same result with the static action
schedule and original-point offsets/failure-kind bitsets (1 initialization,
2 loan, 4 cleanup). `ownership-inspect` also remaps loan states and liveness to
original points. Complete observations can include semantic rejection;
structural or resource failure remains incomplete. The cleanup adapter compares
both action order and every concrete failing path's own failure point.

Reference, index, range and variant projections, calls, source cleanup lowering,
general generation invalidation, complete source normalization and production admission are
outside this implemented core. Subsequent sections specify their required
semantics without asserting that they have landed.

`src/compiler_ownership_dump.tl` validates before rendering. Its v3 format
includes cleanup contract identity/type ownership, obligation parents and
retained operands. The format visits dense tables in index order, encodes each u64 identity component
as two unsigned 32-bit limbs, and length-frames source paths and macro traces.
`compiler_ownership_core_tests.tl` supplies malformed-graph, nested-place,
branch/loop/exit, resource-bound and dump regressions through
`src/tests/compiler_ownership_core_smoke.tl`; the native manifest requires the
smoke on both hosts at optimization levels 0, 1 and 2. Registration states
required coverage, not a claim that every host run has completed.
The core suite also checks a 1,026-place interleaved forest and a 1,025-place
chain within a reduced work budget, exact traversal charges and exhaustion,
and the additional state-cell reservation for the index.
`compiler_ownership_loan_tests.tl` adds capability, reborrow, expiry, CFG,
identity and resource cases through the registered loan smoke. The independent
`loan_model.tl` interprets bounded concrete traces using fresh dynamic tokens
and parent generations; `loan_crosscheck.tl` separately adapts those traces to
production graphs. `compiler_ownership_cleanup_tests.tl` adds retained-dependency
transfer, active-root identity, metadata completeness, Copy-hook distinctions,
ordered diagnostics, explicit resource exhaustion and dump controls. Separate
concrete cleanup adapters compare linear traces and bounded CFG paths against
resource tokens and exact cleanup logs. These core checks do not certify source
programs.

## Primitive selected-occurrence normalization

`src/compiler_ownership_normalize.tl` consumes the exact selected root and
declared return type through `compiler_typed_occurrence.tl`'s lease-checked
getters. It does not traverse AST syntax, inspect unchecked store arrays,
re-infer expressions or consult a type cache. Each executable occurrence may
appear once in the selected tree; repeated child handles are structural
failures, because they otherwise duplicate an evaluation without an explicit
value-reference operation.

The first slice admits canonical Unit, Bool, signed/unsigned 8/16/32/64-bit
integers, F32/F64 and Char. These have distinct deterministic core type IDs;
only their Copy ownership class is shared. Never denotes an exit and receives
no place. Literal categories, unary/binary operand and result types, Boolean
conditions, branch joins, declared returns and binder types are checked before
certification. Unhandled coercions, String, aggregates, references, projections,
calls, captures and globals return explicit Unsupported results.

Literal and computed scalar results receive initialized temporary places.
Reads copy a resolved binder into a temporary before later operands execute.
Short-circuit operators and conditionals produce explicit CFG edges; Return
retains its operand on that exit. Sequence preserves evaluation order and
still validates unreachable selected children. Parameters start initialized.
Initialize denotes one static local declaration event; parameter initializers
and a second declaration initializer for the same binder are malformed.
Structured While has exactly one condition and body occurrence. Their CFG
blocks repeat through edges; no occurrence is duplicated to unroll a loop.
Break and Continue target the nearest enclosing While body, and its condition
is checked outside that body's control scope. Nested traversal restores the
outer targets. Conditions require Bool, bodies Unit or Never, and loop exits
produce Unit. Never-valued condition coercion remains explicitly Unsupported.
Computed Copy temporaries and unique Copy declaration writes use ordinary
Assign in the core, allowing repeated execution without inventing a resource
acquisition. Reads still require initialization on first entry and on every
predecessor, including the zero-iteration path out of a loop.
Assign currently requires initialized primitive storage before writing. That
restriction must be revisited before moved destinations or write-only borrowed
initialization are admitted.

The result owns its core arrays and copies each source path/expansion trace;
no pool, interner or selected-record reference remains. Default normalization
limits are 16,384 intermediate/output records, 128 traversal levels, 4,194,304
work units and the same number of provenance bytes. A hard 128-level stack
ceiling and 1,048,576-record ceiling also constrain caller-supplied limits.
Charges precede record appends and string copies, including repeated provenance
occurrences. Typed-store failures, structural errors, unsupported operations,
normalization resource exhaustion and core rejection remain distinguishable.
Every successful body passes the canonical structural and dataflow checker.

The focused normalizer smoke is registered for both native hosts at opt0/1/2.
Its 40 cases pass natively on Linux at all three levels. Two isolated mutations
remove repeated-occurrence rejection or force a short-circuit RHS to execute;
each builds and fails its expected semantic result with normal exit 1. The
artifacts are under `target/exp/ownership-normalizer-mutations/`.
Two further isolated mutations remove the loop repeat edge or retain an inner
continue target after leaving its lexical scope. Both build and exit normally
with their exact structural witness, while the fixed driver returns 42 with
empty child stderr (`target/exp/ownership-selected-loops/`).
Its tests establish this fixture-driven primitive boundary, not full source
normalization or a retained lowering certificate. Production integration and
the remaining source/representation families below remain migration work.

## Production boundary repairs

The following production repairs were derived while exercising the independent
core. They repair existing compiler boundaries without making that core the
source-language ownership authority:

| Seed family | Implemented invariant | Authored regression |
| --- | --- | --- |
| Aggregate local values (#7900) | A memory-class inline aggregate entering a local binding receives independent inline storage. Assignment snapshots the new value and copies into that existing home, preserving already selected field identity. Initialized inline globals retain their existing home too. The shallow transfer preserves owning-field identity; it does not invoke deep clone. Scalar/register values and references retain their established representation. | `aggregate_local_value_snapshot.tl` and `aggregate_assignment_storage.tl`: projected/wrapped values, nested arrays, overwrites, local/global receiver reassignment, packed locals and MoveOnly Box identity. |
| Aggregate parameter values (#7901) | Ordinary and captured function bodies materialize memory-class nominal parameters into private inline storage using the local-value classifier. Structural ABI transports already provide private storage. Register values, references and descriptor handles retain their existing representation. | `tests/integration/aggregate_parameter_storage.tl`: direct, indirect, tail-position and captured calls; caller values after mutation; explicit mutable-reference control; moved Box identity. |
| Borrowed descriptor payloads (#8119) | A borrowed dynamic-array payload names its descriptor, loaded from the payload slot. Inline aggregate payloads name their inline storage instead. Enum, tuple and fixed-array name patterns use this shared representation rule. | `tests/integration/borrowed_pattern_descriptor.tl`: lengths and elements through each borrowed pattern form. |
| Ordered operand values (#8433) | Earlier scalar and aggregate value operands are captured before later operands execute. Constructors also snapshot the final memory aggregate before any destination writes. The indirect callee is captured before arguments. References preserve their referent identity. Logical operators retain short-circuit control flow. | `call_eval_order.tl` covers direct, indirect and tail calls, callee replacement, widths, binary operands and single evaluation; `aggregate_assignment_storage.tl` covers aliased final struct/enum operands and shallow owning transfers. |
| Raw primitive and assignment order | Raw-pointer, atomic and volatile operands use the same value-capture operation. Assignment captures the logical destination and index once before evaluating the RHS. Dynamic-array stores retain descriptor identity and inline projection offsets, then resolve current backing storage and recheck live bounds at commit. Begin/Ann/Let preserve the selected place; conditional and match receivers merge typed metadata without repeating an arm. Resource and arena scopes retain their cleanup order. Fresh literal/call and clone-out receivers use the evaluated home. | `pointer_eval_order.tl`, `array_set_eval_order.tl`, `array_store_place.tl`, `array_store_scope.tl`, `array_set_bounds_order.tl`, `array_set_zero_bounds_order.tl` under `tests/integration`; lower tests pin both dynamic checks and the single fixed-array check. |
| DCE after value captures | Every surviving instruction is reread after operand propagation has rewritten its slot, including in-place and escaped-slot paths. | `compiler_optimize_tests.tl`: compare/not and bit-test folds under all three survivor paths; isolated stale-instruction mutations fail their expected-value witnesses. |
| C ABI outgoing storage | The stack-space scan uses the same expanded direct/indirect C ABI parameter classification as emission, including aggregate and stored-result calls. | Existing `c_abi_aggregate_no_alloc.tl` plus backend tests for 24-byte and 200-byte arguments on both targets. |
| Frame lifetime at tail transfer | Lowering does not treat a snapshotted aggregate parameter as caller-owned storage. Unchanged incoming reference parameters retain pointer-only forwarding. The optimizer and all backend tail-jump paths decline frame destruction when the canonical IR classification finds local storage/address producers. Ordinary calls remain available. | `tail_call_aggregate_storage.tl` includes deep shared/mutable reference recursion; authored optimizer and backend cases cover direct, extern fallback, indirect, self-recursive and scalar-positive routes. |
| Private constructor storage | Copy elimination requires matching reserved storage, complete initialization, unique definitions and exclusive source uses. The replacement removes the unused destination allocation as well as the copy. Unproved cases keep the ordinary value transfer. | Authored optimizer fixtures cover escaping and incomplete sources, mismatched storage, multiple uses and idempotence; a removed source-use guard fails its isolated witness. |
| Copy/fill loop exit values | Replacing the next counter with its final bound requires the counter definition to follow the memory operation and an exit suffix containing only copies and the loop comparison. Address arithmetic and loads cannot observe the substituted bound. | `copy_call_shifted_step.tl` checks byte and word copies against independent element expectations; authored IR covers shared steps, retained address/load uses and ordinary suffix controls. |
| Parameter storage under move elision | A `let` that moves a whole move-only binding may take over its storage only when that storage is a fresh root or a parameter's private copy. A parameter's incoming storage (a `param` root) is the caller's argument, which may be a forwarded parameter or a bitwise `ptr-read` copy the caller still reads, so adopting it would let writes through the new binding reach the caller. | `tests/integration/param_storage_not_adopted.tl` (the previous lowering returns 1 at opt0 and opt2); the prelude surface producer's module set, which the bootstrap's stage1 smoke checks. |
| Scratch-region resets | opt2's `scratch_reset` frees a loop iteration's allocations only when no candidate pointer escapes. Candidate provenance is tracked monotonically: memory effects never clear it, every value read from a candidate pointer joins it, an address-capable value loaded from candidate memory joins it, and a loop whose candidate is read after the loop keeps no reset. Main's seed freed every fresh element array of a loop that stored them into an outer array. | `tests/integration/nested_array_element_push.tl` (main's seed returns 1 at opt2); scratch-region self-test cases 22-25 (inner-store escape, load-back escape, live-out, self-loop control). |
| Identical function merging | At opt2 a function whose parameters, result, frame, ABI and blocks equal an earlier one's is folded into it, with calls, tail calls and runtime-global initializers redirected. Only functions nothing can tell apart merge: reached only by direct calls and initializers (no `fn@` value, named C-ABI or SPMD call, extern or by-name root), Ordinary ABI, no runtime abort site (a located abort names its own function's source), and debug info off. | `compiler-optimize-merge-functions-self-test`: merge with redirected call and initializer, `fn@` identity, abort sites and differing bodies; mutants dropping the abort or identity rule fail it. |

The native manifest requires these witnesses at opt0/1/2 on both hosts.
Agreement between optimization levels is insufficient: each fixture has an
independent expected result. These cases do not establish that every aggregate
transfer, ABI path or argument form has been migrated.

The copy-loop regression originally returned the wrong values at opt2 while
remaining inside initialized allocations. The same wrong start offset dropped
the first three entries during optimizer label-set growth, producing missing
switch targets and a cyclic GVN child table that exhausted the compiler stack.
The retained artifacts are under `target/exp/ownership-frame-guard` and
`target/exp/aggregate-binding-copy/candidate-call-opt2-csr.gdb`. Nine verified
copy/fill IR fixtures pass the exit-suffix guard; isolated mutations admitting
an early step or omitting the suffix scan fail normally with codes 51 and 52,
while the fixed runner returns 42 (`target/exp/ownership-copy-proof-mutants`).

The canonical safety harness now requires exit 1 plus a matching structured
diagnostic with a primary source location. Diagnostic-then-crash, source-echo
matches, mismatched diagnostic blocks and unexecuted manifests fail its planted
oracle checks. Manifest rows can pin an exact primary `source:line:column`;
generated/imported failures explicitly name their intended primary source.
Legacy rows that pin only a source file remain weaker evidence than a complete
intended-operation location audit.

### Raw buffer boundary seed (#7945)

`ByteBuf.as-bytes` and `as-mut-bytes` now validate the public live length against
the actual backing array before constructing a view. Raw append paths check
their destination extent; the TLS append adapter also validates the existing
live prefix before reserve. Generated cleanup-owning `Vec.set-ref!` checks the
live length against both the element and liveness arrays before taking,
cleaning or writing an element. These guards do not make public representations
unforgeable; they reject malformed representations at these raw-memory
boundaries.

The raw string copy, substring-copy, integer-byte/digit, formatter fill/copy and
formatter Debug range helpers are unsafe declarations. Their callers make
explicit unsafe calls after establishing their source and destination ranges.
Public String copying and formatting APIs remain safe. The fixed-float and
format-options wrappers validate public scale/precision inputs before deriving
raw ranges. The ordinary runtime byte-copy operation still supports overlap;
the compiler-build forward-copy entry requires disjoint storage. No checker
exemption for the raw helpers was added: the pre-existing string wrapper
recognition applies to two-string append/concat functions only.

Fourteen check-only fixtures in `stdlib/tests/string_raw_*_reject.tl` and the
new `format_raw_*_reject.tl` require the unsafe-call diagnostic, including an
import alias and refusal to erase the effect into a plain function value. They
are registered in both stdlib verification scripts; their invalid raw pointers
are never executed. All fourteen were accepted by the published stage0 against
an isolated copy of the pre-change stdlib, and now reject normally with the
intended unsafe diagnostic. `raw_copy_api.tl` exercises explicitly authorized copies
between live, separately allocated ranges.

The native manifest registers ByteBuf full/empty valid controls, oversized,
negative and maximum lengths, mutable-view variants and invalid append lengths;
cleanup-vector valid replacement/cleanup and malformed lengths; and the TLS
negative-length append. All 57 combinations of these modes and opt0/1/2 produced
their specified 42 or 134 exit on Linux with
`target/exp/ownership-ir/typelisp-tail-repaired`; failing cases had empty stdout
and exactly the ordinary bounds-abort diagnostic. Logs are retained under
`target/exp/ownership-wrapper-audit/runtime`. Raw-copy controls passed at all
three levels; existing ByteBuf, formatter API and Debug controls passed at opt2.
Three String and two TextBuf inline tests passed. Invalid formatter shape tests
produced their specified 134 abort. These are focused results, not a claim of
completed Windows runs, full stdlib verification or a measured absence of
performance regression.

The guard cost was measured with the same opt2 compiler and identical valid
10,000-iteration source against an isolated pre-change stdlib and this change.
Cachegrind instruction counts were 290,429 → 380,429 for repeated `as-bytes`
reads, 310,429 → 400,429 for mutable-view reads, and 830,429 → 1,000,429 for
reserved single-byte appends. All six runs returned 42. This is nine extra
instructions per view and seventeen per append, about 31.0%, 29.0% and 20.5% of
these deliberately small loops. The bounds guards remain necessary: public
mutable fields do not carry a validated-range capability. This focused cost
does not establish whole-compiler impact or satisfy a no-regression claim.
The source, binaries and `.cg` files are retained as
`target/exp/ownership-wrapper-audit/byte-buf-bench*`.

### Arena boundary audit and repairs

The 2026-09-30 audit reproduced [#8171](https://github.com/JoNil-Botta/typelisp/issues/8171),
[#8172](https://github.com/JoNil-Botta/typelisp/issues/8172), and
[#8173](https://github.com/JoNil-Botta/typelisp/issues/8173). These are **remaining
production defects at the audited revision**, not repairs supplied by the
standalone ownership core. The raw-authority admission repair below now covers
#8171; bare-owner transfer and parameter confinement still need integration.
Sources and check/build logs are under `target/exp/ownership-arena-audit/`.
Checks used both published `target/stage0/typelisp` (SHA-256
`4880d91f684f9d7edf379a190970aa6aa4fe4b07415d6a658fc132e8f6186581`) and
`target/exp/ownership-ir/bootstrap-dce/stage2` (SHA-256
`6c49ecc2d03d0d4362bde913cd65bee3f66bcb142ce003bafaa5f468e868853f`).
These compiler identities describe that audit, not later bootstrap artifacts.

| Seed | Accepted safe source (`check` exit 0 on both compilers) | Native observation with audited stage2 |
| --- | --- | --- |
| #8171 | `forge.tl` builds `arena.Arena` from 12345; `forge-helper.tl` does so through an integer-taking helper. | `forge.current.opt0` and `.opt2` each exit 139. |
| #8172 | `bare-copy.tl` copies a tracked bare owner into another local; `bare-field.tl` stores it into `Holder`. Both destroy the original and use the surviving handle. | `bare-copy.current.opt0` and `.opt2` each exit 139. The field case was checked, not executed in this audit. |
| #8173 | `bare-parameter.tl` returns an allocation from a bare arena parameter; `branded-caller.tl` passes an inferred branded owner to that same bare helper. | `bare-parameter.current.opt0` and `.opt2` each exit 139. The branded-caller case was checked, not executed in this audit. |

The native programs contain no `unsafe` block; core dumps were disabled for
the deliberately failing executions. A crash is evidence of an admitted bad
program, never a successful safety rejection.

Additional stage2 checks show why a constructor-only restriction is incomplete.
`forge-field-write.tl`, `forge-field-replace.tl`, and `forge-field-borrow.tl`
all pass checking: they replace a live owner's `.handle` with 12345 through
`set!`, `replace!`, or a helper receiving `(&mut owner.handle)`.
The direct field-write program also exits 139 at opt0. The replacement and
mutable-reference forms were checked, not executed. `bare-parameter-handle.tl`
also passes checking while returning the bare parameter itself, so #8173 needs
handle confinement as well as allocation confinement.

Valid controls must remain valid. `local-owner-scalar-ok.tl`,
`parameter-temporary-ok.tl`, and `parameter-unrelated-ok.tl` each check and run
with the expected exit 2 at opt0. They respectively extract a scalar before
destroying the local owner, return a scalar from a helper's temporary allocation,
and return a String allocated outside the parameter arena for use after the
caller destroys that arena. Branding every result with every arena argument
would incorrectly reject the third case. `init-arena.tl` also checks and exits
2: zero is the runtime's valid default-arena identity. The design must preserve
that explicit zero-identity policy while restricting arbitrary raw handles.

Existing rejection evidence covers different boundaries.
`tests/safety/arena_destroy_copied_bare_owner_reject.tl` rejects destruction
*through the copy*; it does not cover destruction of the original followed by
use of the copy. Branded direct-owner duplicate and escape fixtures already
reject. The audit's `branded-parameter-escape-reject.tl` reports E0205 at the
escaping result. At the audited revision, `branded-borrow.tl` reported E0212
for `in-arena a`, and `branded-borrow-deref.tl` reported E0208 for
`in-arena (deref a)`. Direct borrowed branded targets are now admitted as
explained below; the explicit dereference spelling still needs the canonical
non-consuming place context in the source migration.

Raw-handle admission now marks the canonical Arena constructor as an unsafe
callable when declaration environments are built. Module-local bindings,
imports, aliases and hygienic lookups carry that ordinary effect. It also checks
mutation and exclusive field projection at the resolved typed-place boundary.
Reading the inert integer and zero initialization remain valid. Compiler-owned
raw handle wrappers use narrow explicit unsafe expressions; this is a trusted
runtime boundary, not a general ownership-check exemption. Later type-only
queries of an already checked replacement place do not rerun unsafe admission
under a different lexical environment.

Nine `arena_raw_*_reject.tl` fixtures cover direct/helper/alias/value/macro
construction and field assignment, replacement, exclusive borrowing and
mutation through a parameter. `arena_raw_authority.tl` checks valid live-handle
construction, inert reads, zero initialization, explicit unsafe field access
and an unrelated nominal type with the same short name. Artifacts for the
isolated compiler and focused checks live in
`target/exp/ownership-arena-admission/`. These checks do not establish arena
owner transfer or allocation confinement.

The resolved `TcArenaTarget` classifier now distinguishes value, shared and
exclusive access while retaining the canonical nominal identity and optional
allocation brand. The ordinary value-only predicate, branded-region lookup,
`in-arena` admission and handle lowering consume that classification. Borrowed
branded targets use the existing reference-field projection during lowering;
a pointer to their packed storage is not itself an arena handle. The native
`arena_borrowed_target.tl` fixture checks direct and wrapped shared targets,
an exclusive target and subsequent owner use. It returns 42 at opt0/1/2 on
Linux and compiles and assembles for Windows at all three levels. The isolated
compiler has an exact self-build assembly fixpoint and unchanged source hashes
in `target/exp/ownership-arena-target/`. Windows execution is not covered by
that local cross-compilation evidence.

The lint declaration cache retains the constructor kind and declaration module
and consults the same constructor-effect predicate. A moduleless local
constructor whose identity is unavailable goes through typed fallback. Aliases
of the actual Arena retain required unsafe blocks; unrelated same-named types
still receive unused-unsafe findings. The focused and full lint smoke tests
pass in `target/exp/ownership-arena-lint/`.

Remaining repair obligations are retained owner identity despite a bare
binding annotation, phase and generation provenance in the typed core, and
confinement of bare parameter handles and allocations using body-owned regions.
The pure target classifier supplies type and access information, not those
outstanding ownership proofs. The existing unsafe-callable effect machinery
and checked binding facts provide integration points; the raw-authority and
borrowed-target repairs do not implement the remaining obligations.

### Arena owners in the selected route (#8449)

Typing keeps the legacy arena rules (brands, `destroy-safe!`/`rewind-safe!`
admissibility, `in-arena` targets, region escape). The selected producer
publishes arena bodies to the ownership core:

- Canonical types erase arena regions: an arena region tag is dropped, an
  arena lifetime argument becomes one pseudo region, and every branded owner
  `(Arena r)` is one move-only owner type. The typed store records the body's
  arena regions (bare-annotated owner locals, `in-arena` regions, `(Arena r)`
  parameter lifetimes); brands and phase records are recognized globally.
- A bare-annotated direct owner and a phase token are Copy handles in
  `Affine` binders: a whole read is a copy followed by `Invalidate` of the
  binder. A bare `Arena` parameter of an ordinary call, `arena.phase` and an
  `in-arena` target read the owner through a shared borrow (builtin form 123).
- `destroy-safe!` and `rewind-safe!` move their owner place or token, then
  invalidate every scoped binder whose type carries the ended region (all
  scope slots, including shadowed binders). Invalidate is an exclusive access:
  a live borrow of an invalidated value is a conflict, deferred so that an
  uninitialized use of the reference holding that loan is reported instead.
- An `(:invalidate r T)` parameter owns the brand `r`: a marker set at entry
  must be empty at every return, `try` propagation and the end of the
  function. A destroy of brand `r`, or a call passing a value of brand `r` to
  an `:invalidate` parameter, ends it (`EndBrand`). A call's `:invalidate`
  arguments end their brands in the caller as a destroy does.
- A closure local whose environment holds an ended region is invalidated
  with the other binders (see closures below).
- An atomic owner gains thread users when a value of its region is sent on
  a channel (a marker set on that path). Its destroy, rewind or
  `:invalidate` call requires the marker clear and every thread handle in
  scope holding its region joined (empty); a handle is not invalidated by the
  destroy, so the release check reports it.
- A `with` owner allocated in an arena may hold none of that arena's values
  when the arena is destroyed or rewound (`RequireUnheld`, exits 9 and 10): a
  later cleanup of the owner would read freed storage.

### Threads in the selected route (#8449)

Typing keeps the legacy thread rules (a direct nullary lambda for a safe
spawn, sendable captures and messages, raw thread surfaces only in unsafe
code). A safe spawn is builtin form 136: the task closure's environment moves
into the new thread instead of being coerced to the task's function type, and
the spawn result carries the atomic regions its captures hold. A channel send
is an ordinary call moving its message. A thread handle dropped without being
joined is not yet modeled: it detaches a thread that may still use atomic
arena values (see the handover's known gaps).

### Closures in the selected route (#8449)

Typing keeps the legacy closure rules (capture typing, region-tagged and
reference capture restrictions, a capturing `let` local used only as a
callee). The selected producer publishes closures to the ownership core:

- A lambda is builtin form 135 over its captures: each enclosing local the
  body names free is read into the closure value, copied when Copy and moved
  otherwise (a `&mut` capture moves; it is not reborrowed).
- The lambda body is its own body: its captures are `Capture` binders of
  their enclosing locals, and its normalized body gives the call capability:
  once when the body moves or ends a capture, mutable when a capture holds a
  `&mut`, shared otherwise.
- A plain closure (shared, every capture Copy without references or regions)
  is a function value of its `(-> ...)` type. Any other closure's type is its
  environment, a tuple of its capability marker and its captures, so it holds
  the captures' ownership and loans. Coercing such a closure to a function
  type (a result, an argument, a field or a store) is rejected: it would
  erase that ownership.
- A `let` local bound to a closure, or moved from another closure local,
  has the environment type. A call through it uses it per capability: a once
  closure (or a Copy shared one) is read, so a second call of a once closure
  is a use of a moved value; a mutable one is borrowed exclusively; another
  shared one is borrowed.

### SPMD forms in the selected route (#8449)

Typing keeps the SPMD rules of section 5.15 (uniform and varying values,
lane-disjoint writes, no early exits, no `set!` of an outer binding outside
`foreach-active`). For ownership each form is its scalar reference loop:
`start`, `end` and `init` are evaluated once, then the body of every logical
iteration runs in a `while` over an opaque test, with the index (and a scan's
`prefix`, a compact's `slot`, a serialized lane) bound to a fresh value at the
top of the iteration. A reduction or compaction then yields a fresh scalar. A
move of an outer owner in an iteration is therefore loop-carried, and a borrow
live across the form is checked against every iteration.

### Confirmed cleanup-vector representation gap

The previously unconfirmed cleanup-owning `Vec` construction path in #7945 is
constructible in safe source. A minimal witness creates `tokens.new` inside a
`with` cleanup scope, writes its public `len` field to 1, then calls
`tokens.set-ref!` at index 0 with a new cleanup-owning token. The published
baseline accepts it. The retained check-only fixture is
`target/exp/ownership-wrapper-audit/cleanup-vec-forged-length.tl`; it was not
executed because its raw write is known to lack a backing-storage bound.

In the generated cleanup specialization, `set-ref!` checks `index < v.len`,
then calls `__tl_array-take!`. That primitive's false result is not an abort.
The subsequent raw pointer write occurs before the checked live-bitmap write,
while `new` supplies empty slot and bitmap arrays. Thus public construction
and field mutation could reach the raw write without proving either backing
extent in the audited baseline. The implemented `set-ref!` repair now validates
the public live length against both backing arrays before extraction, cleanup
or replacement; `cleanup_vec_live_bounds.tl` exercises the failure boundary.
The ordinary Copy specialization uses checked
`array-ref` assignment and does not have this particular raw-write gap.
This resolves the confirmed length-forgery path; it does not establish complete
representation safety for the vector family.

### Loan origins: Rust's region method (#8449)

The normalizer first decided which loans a value may hold by tracing value
flows between places (points-to origins). Whenever a reference's target was
not a place the graph names, it needed another rule: opaque referents with
flows both ways, call store contracts and a deep walk behind them, a callee
flow for closures, caller-memory marks, placeholder referents typed like
by-value parameters. Six review rounds each found more shapes those rules
missed, all of one kind: a reference stored through a chain of `&mut` into
memory the graph does not name. A rustc oracle (below) found 95 more in 3,000
generated programs with no reviewer. The model asked where a pointer points;
Rust never asks that. Origins now follow Rust's borrow checker (NLL, RFC 2094;
Polonius states the same rules as Datalog): type-directed and modular, with
the lifetimes the typechecker already carries in every type it publishes.

- **Regions.** A region is a pair of a root place (a local, a temporary, a
  parameter) and a lifetime name its type spells. A projection of a root
  (field, element, box contents, dereference) uses the root's regions: the
  typechecker instantiates projection types with the root's names. A
  parameter's signature lifetimes and the return type's are universal regions,
  shared by every parameter and live at every return. Each call instantiates
  its callee's signature lifetimes as fresh regions of its own.
- **Shapes.** A type's shape lists its lifetime positions in order, each with
  its variance (`&` covariant; the referent of `&mut`, a nominal lifetime
  argument and a function type invariant) and the reference it lies under.
- **Constraints.** An edge `x -> y` means the loans of `x` are loans of `y`.
  Every value transfer relates the source's shape to the destination's
  position by position: covariant one way, invariant both ways. A borrow's
  referent positions are the borrowed place's own regions; when its type does
  not spell them all (a closure's captures), they relate with its inner
  regions, and its outer region, which holds the borrow's own loan, only
  outlives them. A reborrow's type
  is a projection of its root's type, so its names are the root's regions:
  its outer region is outlived by the root's region of that name (the typing
  below picked the reference that bounds it), and every inner name is that
  region itself. A call relates its operands to the callee's formal parameter
  types and the formal result type to its result, through its own instance of
  the signature; a return relates the returned value to the universal return
  regions. Well-formedness: each region outlives the references it lies under
  (`(&mut r (T s))` has `s` outliving `r`), so a call result typed with `r`
  keeps the loans behind it. A transfer whose shapes do not line up relates
  everything both ways, and an operation without a signature (a primitive, a
  constructor) may put any operand's loans in its result.
- **Loans and uses.** A borrow's loan starts in its reference's outer region;
  region loan sets are closed over the edges. A use of a root demands every
  loan of every region of the root, and every return demands every universal
  region. The core's loan liveness and conflict checks are unchanged.
- **Where a reference points.** The core keeps loans in a tree, so a reborrow
  names one parent loan and a dereference of a local reference binder is
  checked against the loan it was initialized from. That one question is
  answered on a second graph in which each parameter's regions are its own
  and outlives edges (reborrows, well-formedness) are left out: a reference
  points at the loans that reached its outer region by value. A joined or
  unknown answer still fails closed (E0211).

**Typing: a reborrow is bounded by what it reborrows through.** A borrow
through a reference lives no longer than any reference on its path, up to and
including the first shared one (Rust's supporting prefixes); a well-formed
`(&mut o (Holder i a))` has `i` outliving `o`, so the reference closest to the
root bounds it. `(&mut (deref (deref h).m))` with `h : (&mut o (Holder i a))`
was typed `(&mut i ...)`, letting a function hand out the holder's exclusive
reference while the holder could still use it; main accepts that
(`reborrow_through_mut_holder_bound_reject`,
`reborrow_through_shared_holder_bound_reject`) and rejected the `o` version
Rust accepts (`reborrow_through_mut_holder_bound_ok`). A stored shared
reference is still copied out with its own lifetime.

A mutable iterator over a stored `&mut` therefore lends: its item borrows the
iterator, as a Rust lending iterator's does (a non-lending one needs private
fields and an unchecked split). `stdlib/vector`'s `next-mut` takes
`(&mut item (IterMut source))` and returns `(IterMutNext item)`
(`vector_iter_mut_item_outlives_iterator_reject`), and the
safety and integration programs that typed a `&mut` item with the source
lifetime only through the old rule now name the iterator's borrow; their checks
are unchanged. Main's seed cannot type the lending body, so `vector` selects
the earlier form under a seed: every compiler from this one enables the cfg
name `compiler-reborrow-bound` whatever its `--cfg` flags (as Rust's
`cfg(bootstrap)` selects library code by compiler). It and the seed form go
once the seed has this rule.

**What this replaced.** Opaque-referent flows and their fixpoint, call store
contracts and their deep walk, the closure callee flow, caller-memory marks,
and placeholder referents typed like by-value parameters. Opaque referent
*places* remain: they are what a dereference reaches, for conflicts, and they
use the regions of the reference they are reached through.

**Validation against rustc.** Three generators render one random program as
TypeLisp and as Rust using only constructs whose ownership semantics coincide,
and rustc's verdict is the oracle: `main` bodies over pairs, reference holders,
jobs, boxes and arrays with stores, reads, writes, pushes and calls (1,000);
function bodies over lifetime-carrying parameters (nested `&mut`, by-value
holders, boxes, vectors) with loops and branches (3,000); and the first with
lending signatures and the vector iterator against a hand-written Rust
`IterMut` of the same signature (2,000). TypeLisp accepts no program rustc
rejects in any of them. It rejects none rustc accepts among the function
bodies; the 29 and 51 it rejects among the others are typing differences, not
ownership (a lexical owner-named lifetime in an annotation or field type,
E0206, and a region-tagged constructor value, E0205). Every review finding is
a fixture, each oracle hole family has one
(`region_signature_store_then_write_reject`), and the precision cases the
second graph decides are pinned (`region_view_call_argument_ok`,
`region_by_value_holder_store_reborrow_ok`).

**Cost.** `__tl_array-push!` copies its whole array, so every column the
region pass grows is grown geometrically. Checking the compiler takes the same
memory as before the change (1.50 GB) and 4% less time.

### Verdict and diagnostic changes from the rebase onto main 08eae4017

Main's semantics were ported into the selected producer and normalizer. Where
the ownership graph decides differently from main's former walkers, the change
is deliberate and has a regression twin:

- **Soundness fixes (main accepted these programs; the full list is the
  table below).** A shared element borrow
  stays live across a `&mut` reborrow of its slice
  (`slice_element_borrow_with_mut_slice_reject`,
  `slice_element_borrow_with_mut_param_reject`). A call relates its arguments
  through its signature, so an argument stored through another's `(&mut T)`
  keeps its loans in the borrowed place (`call_store_contract_reject`, valid
  twin `call_store_contract_ok`).
- **Precision: non-lexical lifetimes.** A borrow ends at its last use, as in
  Rust, where main's walkers held it to the end of its scope; code after a
  `return` is unreachable and checks nothing; a part moved out by a pattern
  leaves the rest readable. So main's reject fixtures
  `mutable_reference_reject`, `mutable_reference_same_field_reject`,
  `mutable_reference_field_element_reject`,
  `mutable_reference_reborrow_outer_live_reject`,
  `dotted_field_mut_borrow_bound_reject`, the four
  `vector_iter_{mut,shared}_{push,set}_live_reject` and
  `tuple_match_pattern_source_reuse_reject` now use the first borrow (or the
  moved part) after the conflict and still reject; main's versions, and main's
  typecheck tests with dead borrows or code after `return`, are accepted.
- **Coverage: cleanup-owning aggregates holding references.** A struct or
  enum with a declared cleanup whose lifetime arguments hold references is
  a holding type (`tc-selected-holding-type?`) that also carries its cleanup
  obligation: its loans stay live to the explicit discharge, which uses the
  value. Its bodies failed closed (E0211) before, though main accepts them
  (`mir_cleanup_holder_param_ok`, `mir_cleanup_holder_assign_reject`, valid
  twin `mir_cleanup_holder_assign_ok`, `mir_cleanup_holder_return_reject`,
  `global_call_returned_referent_ok`).
- **Precision (main rejected a valid program).** A reassigned reference
  binding is split into its reaching definitions, so a read sees exactly the
  loans that can reach it: `reassigned_ref_ok` is accepted, while
  `reassigned_ref_branch_reject`, `reassigned_ref_loop_reject` and
  `reassigned_ref_copy_reject` keep main's rejection. A binding that also
  receives a value another way (a store through a call argument, a store
  through a reference to it, a field write) is not split
  (`reassigned_ref_call_store_reject`, valid twin
  `reassigned_ref_call_store_ok`). A store into a field of an owned array
  element flows the stored value's loans into the array, and `replace!` of an
  element flows the new value in and the array's loans into the value taken
  out (`mir_array_element_field_store_reject`,
  `mir_array_element_replace_reject`); main rejected the valid twin
  `mir_array_element_field_store_ok`. An access through a reference whose
  referent the graph does not name (one returned by a call, held in a field
  or behind another reference) uses that reference's regions, so a store
  through it reaches every holder of those regions and a read sees what they
  hold (`call_store_contract_returned_ref_reject`, valid twin
  `call_store_contract_returned_ref_ok`, `mir_opaque_referent_read_reject`).
  A reborrow's parent is the one loan its binder points at, not the loans its
  referent holds: a reborrow of a `&mut` to a value holding a reference was
  rejected with E0211 before (`mir_reborrow_holder_ok`;
  `mir_reborrow_call_store_reject`, `mir_reborrow_param_call_store_reject`).
- **Holes the cutover opened, closed (third review).** Main's former walkers
  rejected these programs, mostly as moves out of a reference; the graph
  accepted them until:
  - a box holding references was classed as a reference, so its contents
    were an opaque referent holding none of its loans. A box's contents are
    its own place whatever they hold (`mir_box_holder_read_reject`, valid twin
    `mir_box_holder_read_ok`, `mir_box_holder_element_push_reject`,
    `mir_box_holder_store_reject`, and `mir_box_holder_nested_store_reject`,
    which main accepted too), and a part moved out of it takes the box's
    loans along (`mir_box_holder_move_out_reject`,
    `mir_box_holder_struct_move_out_reject`, valid twin
    `mir_box_holder_move_out_ok`);
  - a reference stored through a `&mut` reached from a parameter, at any
    depth, lands in a signature region, live at every return
    (`mir_nested_param_store_then_grow_reject`,
    `mir_nested_param_field_store_then_grow_reject`; main rejected the valid
    twin `mir_nested_param_store_ok` as a move out of a reference). A
    by-value parameter holding references has signature regions too, so
    loans stored through the `&mut` references it holds (or one moved out of
    it) stay live until return (`mir_by_value_param_store_then_grow_reject`,
    `mir_box_param_move_out_store_reject`,
    `mir_by_value_deep_holder_store_then_write_reject`,
    `mir_by_value_holder_call_store_then_write_reject`, valid twin
    `mir_by_value_param_store_ok`);
  - a store through a `&mut` held inside a call's `(&mut T)` argument: the
    call's instance of its signature relates the stored argument to the
    region the inner `&mut`'s referent names
    (`call_store_contract_holder_reject`, `mir_job_field_store_after_rebind_reject`,
    valid twins `call_store_contract_holder_ok`,
    `mir_holder_disjoint_lifetime_store_ok`);
  - a call through a closure passed none of the closure's captured loans to
    its result (`mir_closure_result_loan_reject`, valid twin
    `mir_closure_result_loan_ok`). A closure value's regions, its captures',
    relate to the call's whole signature instance;
  - a `&mut` reached through a `&` took an exclusive loan on its referent.
    Through a shared loan every inner loan is shared, whatever the access, so
    a push, an element or field store, or a mutable borrow through it is
    rejected (Rust E0596/E0594: `mir_shared_mut_reference_push_reject`,
    `mir_shared_mut_reference_field_push_reject`,
    `mir_shared_mut_reference_field_set_reject`).
- **Lowering and optimization of the forms the graph now accepts.** Main's
  walkers rejected `(deref r)` of a non-Copy referent as a move, so lowering
  never met it. A reference to a dynamic array is the array's header itself:
  `(deref r)` now yields `r` instead of loading through it (a read segfaulted,
  a push or element store was lost), and a whole `set!` or `replace!` through
  it copies the new header into the referent (main also lost that store).
  Borrowing a Box's dynamic-array contents loads the handle out of the box's
  slot. An inlined field store through `&mut` into a register-resident struct
  was lost at opt1 and opt2: load forwarding treated a variable-offset store
  into an ordinary object as an array element store, and took an i64 word and
  a narrower field to be distinct memory. An i64 word now overlaps i32, i16
  and raw-pointer fields (f64 overlaps f32) in load forwarding and loop
  hoisting, and such a store kills every entry on its object; main
  miscompiled the same shapes through a copied reference or a raw-pointer
  field. A variable-index location's key now includes its scale: unsafe code
  reading one buffer by word index and by byte index was served the wrong word
  at opt2, on main too (`unsafe_scaled_index_views`). A by-value `bool` or other narrow local passed as `(&mut local)` is
  read back at its own width (a word read made a loop flag read as true
  forever at opt2). `deref_place_forms`, `mut_borrow_narrow_writeback` and the
  optimizer tests `load-cse-register-word-store-filter` and
  `load-cse-scaled-field-scale-key` pin these.
- **Relaxation.** Moving a non-Copy part without cleanup out of owned Box
  contents by projection consumes the Box, instead of being rejected as main's
  aggregate-path limitation did (`box_deref_non_copy_projection_move_reject`
  is now check-ok; `box_deref_projection_move_consumes_box_reject` rejects a
  later use of the Box). Parts that carry cleanup are still rejected.
- **Main's verdicts kept by new graph rules.** A store into a parameter
  referent keeps its loans live until return
  (`mut_param_store_then_write_reject`,
  `mut_param_whole_store_then_write_reject`), replacing the normalizer's
  former fail-closed refusal of such stores. A builtin that only reads its
  receiver (form 124) reborrows a `&mut` slice as shared, so a disjoint element
  update after it stays accepted (`slice_rest_element_update_ok`). Or-patterns
  with bindings are distributed over their alternatives, up to 256 rows,
  before normalization. `try` inside `with-arena` strips the arena tag of its
  propagated value.
- **Diagnostic location.** An operation a macro template generates is
  reported at the operation in the template, with the importer's call site as
  the expansion label (`foreign_global_macro_write_reject`: main put the
  primary span at the call site). The safety oracle pins such cases to the
  file holding the operation. A write whose receiver conflicts with a live loan is
  reported as main reports it, at the receiver operand: `b` of
  `(set! (deref b) v)` and `a` of an element store, push or take of `a`.
  Stores and pushes read as an assignment to the written place, naming a
  literal element (`box_set_through_reference_borrow_live_reject`;
  `mutable_reference_reborrow_outer_live_reject`,
  `slice_view_shared_dynarray_push_reject` and
  `two_phase_mutable_call_mutate_reject` keep main's expected text).
- **Earlier diagnostic.** A mutable borrow taken again on a loop trip while
  the previous trip's borrow is still held is rejected at that second borrow,
  where Rust reports E0499, instead of at a later write
  (`loop_mut_borrow_continue_edge_reject` and
  `loop_mut_borrow_operand_continue_reject` now expect
  `cannot mutably borrow borrowed place`).
- **Debugging.** A compiler built with `--cfg ownership-mir-dump` prints each
  normalized body before the core check.

#### Every safety case main accepts and this compiler rejects

These 66 `check-fail` cases of `tests/safety/manifest.txt` pass `check` on
main at be3f903ee and are rejected here, each with the diagnostic its manifest
row names. Each fixture's leading comment states the rule. One of
them was an accepted case in main's manifest:
`borrow_call_arg_final_use_before_nested_write_ok` is the same program as
`borrow_call_arg_nested_write_before_call_reject` (Rust rejects it with
E0506). The only other verdict change to a case main's manifest lists is the
Box projection-move relaxation above. Main's integration programs
`ref_return`, `ref_tuple_return` and `ref_fixed_array_return` returned
borrows of by-value parameters and now return them through reference
parameters; main's typecheck tests that accepted those signatures and an
implicit `f32` to `f64` widening now expect the rejections.

| Hole closed | Cases |
| --- | --- |
| Raw arena authority (#8171): the `Arena` constructor and mutation of its `handle` field need `unsafe` through every route (helper, import alias, value position, macro, replace, borrow, parameter). | `arena_raw_constructor_reject`, `arena_raw_constructor_helper_reject`, `arena_raw_constructor_alias_reject`, `arena_raw_constructor_value_reject`, `arena_raw_constructor_macro_reject`, `arena_raw_field_write_reject`, `arena_raw_field_replace_reject`, `arena_raw_field_borrow_reject`, `arena_raw_field_parameter_reject` |
| Moves into containers and constructors: a pushed, stored, boxed or constructed value (direct, macro-expanded, or a comptime `Expr`) is moved; a loop cannot store the same owner on every trip. | `mir_array_push_moved_reject`, `mir_array_set_moved_reject`, `mir_array_loop_store_reject`, `mir_box_construct_moved_reject`, `mir_macro_constructor_double_move_reject`, `mir_comptime_syntax_move_reject` |
| Partial and match moves: a value with a moved field cannot be used whole; matching a field by value moves its payload (twice, or on the next loop trip); a loop flag does not reinitialize a moved cursor; a computed index may name a moved element. | `mir_field_partial_whole_reject`, `mir_match_field_twice_reject`, `match_field_payload_move_in_loop_reject`, `mir_match_loop_moved_reject`, `mir_array_literal_move_computed_read_reject`, `mir_array_literal_move_computed_store_reject` |
| Moves out from behind references and out of elements (Rust E0507): a non-Copy element or payload reached through a shared reference, a Box view, a nested match or an `if` cannot be moved out; a computed-index element of an owned array cannot move; a by-value match of an element moves it. | `mir_element_move_through_ref_reject`, `mir_element_move_owned_param_reject`, `mir_element_match_reject`, `mir_view_if_move_out_reject`, `mir_referent_match_move_out_reject`, `mir_referent_box_match_move_out_reject`, `mir_referent_nested_match_move_out_reject` |
| Writes through shared references and views: an element or field write, a mutable borrow of a view binder, the `__tl-box-place` bridge and a control-flow store receiver reached through `&` are mutations through it. | `mir_array_field_set_through_shared_reject`, `mir_local_ref_field_set_shared_reject`, `mir_view_binder_write_reject`, `mir_view_binder_mut_borrow_reject`, `mir_box_bridge_shared_write_reject`, `mir_store_receiver_through_shared_reject` |
| Loan conflicts: an earlier argument's borrow lives until the call; one `&mut` cannot fill two mutable parameters; a view of a matched or projected part keeps its owner borrowed; a control-flow store receiver writes the place it selects (and that place must not be moved by the right-hand side); a mutable borrow of a register-resident local cannot outlive the call; a shared element borrow across a `&mut` reborrow of its slice; stores through call arguments, including into a binding assigned whole more than once, through a reference a call returned and through one an implicit reborrow made; a store through a `&mut` held in a box. | `borrow_call_arg_nested_write_before_call_reject`, `mir_ref_nested_write_owned_reject`, `mir_ref_alias_mut_param_reject`, `mir_view_scrutinee_conflict_reject`, `mir_view_field_assign_reject`, `mir_store_receiver_shared_borrow_reject`, `mir_store_receiver_mut_borrow_reject`, `mir_store_receiver_moved_reject`, `mir_by_value_borrow_escape_reject`, `slice_element_borrow_with_mut_slice_reject`, `slice_element_borrow_with_mut_param_reject`, `call_store_contract_reject`, `reassigned_ref_call_store_reject`, `call_store_contract_returned_ref_reject`, `mir_reborrow_call_store_reject`, `mir_reborrow_param_call_store_reject`, `mir_box_holder_nested_store_reject` |
| Arena invalidation: destroying an arena invalidates every binder carrying its brand, including a shadowed one. | `mir_arena_destroy_shadowed_use_reject` |
| A reborrow through a reference lives no longer than it (Rust's supporting prefixes): `inner` handed out the `&mut` a holder stores while the holder could still use it, a shared view of it the same way, and a vector's mutable iterator item, which now borrows the iterator, outlived the iterator or a push to its vector. | `reborrow_through_mut_holder_bound_reject`, `reborrow_through_shared_holder_bound_reject`, `reborrow_stored_generated_vector_item_source_live_reject`, `vector_iter_mut_item_outlives_iterator_reject` |
| A reference joined from two branches inside a loop still holds the loan of the branch that borrowed the element written next, when it (or a copy of it) is read after the write. | `mir_nll_loop_if_join_reference_live_reject`, `mir_nll_loop_if_join_reference_copy_reject` |
| A borrow taken again on every loop trip stays live while a reference still holds an earlier trip's borrow and is read after a write to the borrowed place (Rust E0506). | `mir_reference_loop_reissue_held_reject` |
| Returned borrows of by-value parameters (Rust E0515): a by-value parameter's storage belongs to the call, so a return type cannot name its lifetime, directly, through a field or inside a tuple or array. Main accepted these; with `in-arena` placing the parameter in an arena, the returned reference was read after `destroy-safe!` (freed memory). | `return_by_value_param_reference_reject`, `return_by_value_param_field_reference_reject`, `return_by_value_param_aggregate_reference_reject`, `return_by_value_param_arena_use_after_destroy_reject` |
| No implicit numeric conversions (SPEC 3.8): an `f32` cannot stand for an `f64`. Main accepted one at returns, joins and stores and lowered the `f32` bits unconverted (the values read as 0); only call arguments were converted. | `scalar_implicit_widening_reject` |
| Fail-closed bounds and declarations: a body past the graph's fixed bounds is rejected with the reason, never trusted; a struct or enum holding a reference must declare its lifetimes. | `mir_resource_limit_reject`, `mir_free_lifetime_field_reject` |

## Revalidated base and existing authorities

The implementation base is `50ccfe6ef4b860726bc585b0328d9a91ed067c8b`
(`origin/main`, 2026-09-30). The previous safety worktree base, `24b6349ee`,
predates relevant repairs. The inventory below describes the updated base.
Function names are navigation anchors; line numbers are deliberately omitted
because these compiler modules change frequently.

| Producer or consumer | Current implementation | Migration disposition |
| --- | --- | --- |
| Expansion and specialization | `compiler_typecheck_api.tl`, `typecheck-compiler-request-checked`; `compiler_specialize.tl`; macro expansion in `compiler_typecheck_core.tl` | Normalize the fully expanded executable bodies; retain macro and source origins. Check executable transformers before executing them. |
| Declaration and type admission | `tc-program-source-types-policy-ok`, `tc-build-top-env`, `tc-check-fn-decl-body` | Retain declaration/type diagnostics and explicit unsafe admission. Replace body ownership calls at the typed-body boundary. |
| Per-expression types | `TcBodyState`, `tc-body-type-fact-record!`, `tc-body-type-fact-lookup`, `tc-body-type-facts-start-consuming!` | Reuse resolved types while their owning pools are live. Missing facts require explicit typed construction or a diagnostic, never an invented type. |
| Contextual binding types | `TcCheckedLetBindingFact`, `tc-checked-let-binding-fact-record!`, `tc-checked-let-binding-fact-lookup` | Reuse the checked binding type and arena transition keyed by declaration/body/binding occurrence. A shared AST expression ID alone is not a contextual typing identity. |
| Place and binding resolution | `TcBorrowPlace`, `tc-borrow-place`; `TcMovePath` and its append-only projection store; scoped type environment | Reuse resolution and type rules; replace intern-name roots with body-owned binding identities and typed projections. |
| Move state and cleanup ownership | `TcMovedSet`, `tc-move-check-body-id`, `tc-move-check-expr`, `tc-move-check-result-expr`, `tc-move-check-global-initializer-id` | Replace their body-level authority with initialization/move dataflow. Existing path predicates are migration evidence, not a second checker. |
| Loans and last uses | `tc-borrow-check-body-id-with-ret`, `tc-borrow-check-expr`, loop/path/arm walkers, `BorrowLending` and `BorrowPending` facts | Replace syntax scans and pending-expression horizons with graph liveness, reaching origins and loan dependencies. |
| Lifetime and arena flow | `tc-lifetime-subst-*`, `tc-region-outlives-or-matches`, `tc-ensure-region-value-can-flow-into`, safe-arena call effects | Reuse signature elaboration; give region constraints and invalidation one explicit graph representation. |
| Closures | `tc-lambda-call-capability-with-locals`, capture scans, closure codes in `TcBodyState` | Normalize nested bodies independently; infer capture transfers and callable contracts from checked bodies. Do not derive a successful contract from a discarded analysis error. |
| Cleanup metadata | `tc-check-struct-field-cleanup-fn`, `tc-check-enum-payload-cleanup-fn`, resource expression checking | Instantiate ordinary callable contracts for implicit calls, including unsafe effects and retained references. |
| Source-to-machine lowering | `compiler_lower.tl`, `lower-function`, `lower-call-args-as`, `lower-cleanup-stack-push-move-aware`, `lower-with-resource`, `lower-with-arena` | Consume checked value/place transfers and cleanup plans before removing regions or choosing ABI storage. |
| Generated functions | clone handoff, `lower-function-with-captures`, global initializer and cleanup synthesis, SPMD helpers | Admit every generated body or verify a narrowly specified primitive template. Compiler origin alone is not a certificate. |
| Optimizer and backend | `compiler_ir_types.tl` effect classification; `compiler_optimize.tl` CFG, verification, call-memory and alias analyses; backend ABI/frame validation | Keep separate machine-level verification. Couple derived analyses to the exact IR revision and invalidate them on mutation. |
| Runtime and libraries | `stdlib/arena.tl`, ownership-bearing collections, thread/task/channel/sync wrappers, runtime primitive declarations | Keep explicit trusted contracts; reuse the concurrency authority registry and mutex validation. Static checking cannot establish an unsafe implementation's actual bounds or synchronization. |

The existing three-address `CompilerIrInstr` representation is already below
the point where `lower-function` removes arena regions and classifies aggregate
arguments and results. It therefore cannot recover all source ownership facts
from loads, pointers and descriptor addresses. Ownership IR belongs immediately
after type-directed normalization and before this destructive lowering. It is
not a second machine optimizer IR.

Existing repairs on this base that must survive migration include:

| Family | Landed implementation evidence | What this inventory establishes |
| --- | --- | --- |
| #7921 member identity collisions | `f42ddf10e`, widened registry handles | The repair exists; new identities must also avoid packed-key collisions. |
| #7992 bounds-dependent hoisting | `e2206a247` | Bounds evidence is an optimizer obligation independent of source acceptance. |
| #8085 pointer-load speculation | `d1e7922fc` | Readability evidence is required before LICM moves a load. |
| #7944 cleanup owner versus arena reclamation | `e5d20969e` | Cleanup is a retained use that invalidation must inspect. |
| #8266 shadowing and move state | `453f7ab8d` | Restoring outer move history is a required identity regression. |
| #8268 value-producing move forms | `cccb7997f` | Consumed results must normalize identically through wrappers. |
| #7752 concurrency authority | `d47fe5071` | Reuse the shared runtime registry. |
| #7755 mutex and guard authority | `862578fca` | Reuse authority-family and lifecycle validation. |
| #7541 inlined SPMD helper arguments | `133edda85` | Ordered, single evaluation already has a lowering regression family. |

These are source-history findings, not fresh executions of their complete test
matrices. The production repair table above records the newly exercised value
snapshot families; other seed issues still require their own discriminating
reproducers and recorded observations. An issue's
closed state does not establish migration correctness.

Existing discriminating fixtures to preserve include `move_shadow_*`,
`move_value_*`, `with_owner_destroy_*`, `with_owner_other_arena_destroy_ok`,
and `wide_struct_*`/`wide_enum_*` in `tests/safety`; `licm_element_bound.tl`,
`licm_raw_deref.tl` and `spmd_inline_helper_call_by_value.tl` in
`tests/integration`; and `concurrency_registry_api.tl`,
`concurrency_registry_exhaustion.tl`, `sync_mutex_authority.tl` and
`sync_mutex_exhaustion.tl` in `stdlib/tests`. Negative runtime authority tests
must remain distinct from semantic-rejection fixtures. Their canonical
manifests, rather than this representative list, own complete execution.

## Semantic core and identities

The target model separates these concepts:

* A **value** is a typed result. Scalar bits, aggregate contents, a reference
  capability and an arena handle have distinct semantic types even when their
  physical representation is a machine word.
* A **place** is a storage root followed by typed projections. A place address
  or an aggregate descriptor is not an owned copy of its contents.
* A **binding** names one storage root in one body. Two binders with the same
  interned spelling are distinct. A temporary is also a root with an explicit
  storage lifetime.
* A **loan** grants shared or exclusive access to a place during a region;
  a reborrow records its parent loan and suspends the appropriate parent access.
* An **arena generation** identifies live backing storage. A value may depend
  on several generations, including dependencies retained inside an aggregate
  or closure. A bare handle cannot create generation authority.
* An **obligation** records a pending cleanup use of a particular owner/subplace
  and the callable contract that cleanup will invoke.

Body, revision, local, temporary, block, place, loan, region and obligation IDs
have distinct typed interfaces. Dense ordinals are meaningful only with their
body owner and revision. Projection identity is structural; multiplying an
intern ID by a presumed maximum member count is forbidden. Owner/generation
and ordinal exhaustion returns an explicit resource-limit error before an ID
can wrap. No stale body reference becomes current by numeric coincidence.

The full normalizer must retain a type for every projection. Distinct fields
or tuple components of the same live aggregate are disjoint. Literal array
indices are disjoint when unequal and in bounds. Dynamic indices overlap
unless a checked range proof establishes disjointness. Nested slice indices
are interpreted relative to their parent range; two different slice bindings
do not establish disjoint storage. A prefix overlaps its descendants.
Dereferences use the referent provenance, not merely the reference variable's
identity; unknown pointer provenance supplies no safe disjointness fact.
Variant projections require the corresponding discriminator refinement on the
incoming edge. Different variants are not simultaneously readable fields.

## Operations, order and exits

The following is the **required target instruction set**, not a list of
operations already implemented in the initial core:

| Operation | Concrete meaning and static obligation |
| --- | --- |
| `StorageLive` / `StorageDead` | Create or retire a root. Retirement rejects escaping loans and unmet cleanup obligations. Re-entry in a loop creates a new dynamic instance of the same static root. |
| `Init(place, value)` | Install a complete typed value into permitted uninitialized storage; initialize exactly its constituent leaves. |
| `Copy(place, temporary)` | Read initialized Copy contents at this point. Later writes to the source cannot change the captured value. |
| `Move(place, temporary)` | Transfer initialized contents and dependencies, mark source leaves uninitialized, and transfer cleanup responsibility. |
| `Assign(place, value)` / `Replace` | Evaluate the destination projections and RHS once in specified order; enforce access loans; account for the previous obligation before overwrite. `Replace` returns the old value and leaves the place initialized. |
| `Borrow` / `Reborrow` | Create a capability with an origin, mode and region; check conflicts against overlapping active loans and parent permissions. |
| `Call` | Evaluate the callee and ordered argument temporaries, instantiate the checked signature/effects, transfer values, activate applicable reservations, and produce result dependencies. |
| `Construct` / `Project` / `Discriminate` | Preserve aggregate leaf types and dependencies; a discriminator edge justifies a variant projection. Partial construction has explicit initialized leaves. |
| `CleanupUse` / `Cleanup` | A potential retained use precedes checking; post-analysis elaboration emits exactly the live obligations on an executing edge. |
| `ArenaCreate` / `Allocate` / `Invalidate` | Create authority, attach generation dependencies, or retire a generation. Invalidation requires exclusive authority and no live dependent values, loans or cleanup uses. |
| `UnsafePrimitive` | Record the primitive identity, caller obligations and stated effects. Unsafe permission does not waive move or loan rules. |
| `Goto` / `Branch` / `Return` / `Abort` | Explicit successors and exit kind. A return transfers its result after checking escapes and discharging promised cleanup. A terminal abort has the specified observable failure semantics. |

Every value argument is captured before evaluation of the following argument,
including a scalar variable read. A reference argument records a borrow of its
intended place rather than copying the pointee. Short-circuit operators become
branches; untaken operands are not evaluated. An unused argument still performs
its effects and specified failures. Constructor fields and pattern projections
have the same explicit order and single-evaluation rule.

Loops contain entry, condition, body, backedge and exit blocks. `break` goes to
the nearest loop exit, `continue` to its iteration edge, and `return` to the
current body's return edge. A lambda has a separate body and exit namespace.
`try` branches between a continuation and an early result propagation edge;
it is not unconditional divergence. Cleanup is attached to each edge leaving
the relevant scope before divergence is used to remove a successor. A failing
operation cannot be freely reordered across another observable failure.

Cleanup obligations are not inferred from every borrow used while constructing
an owner. Only operands retained by the resulting value or cleanup contract
remain live. This distinction permits a transient initializer borrow to end
even inside a `with` scope.

## Abstract interpretation and preservation obligations

For a finite body, let `P` be its finite tracked leaf places, `L` its loans,
`G` its arena generations, `O` its obligations and `V` its typed values. The
intended product state contains:

* reachability;
* definitely initialized leaves `I ⊆ P` and possibly initialized leaves
  `M ⊆ P`, with `I ⊆ M`;
* origin sets `Origins : V → powerset(P ∪ G ∪ L)`;
* possible live loans, parent dependencies and reservation/activation state;
* possible live cleanup obligations with their initialized owner leaves;
* live generation/authority facts and region constraints.

At a join of reachable predecessors, definitely initialized sets intersect;
possibly initialized sets and possible origins, loans and obligations union.
An unreachable predecessor contributes no executable state. Missing origin or
contract metadata is an explicit unknown, not the empty dependency set.
Definite initialization and possible initialization have different purposes:
reads require the former; conditional cleanup elaboration uses the latter.
The initial core implements a smaller initialization component; it does not
implement this entire product lattice.

Transfers use fixed typed operands. A read requires every constituent leaf to
be definitely initialized. A move removes those leaves from both initialization
sets; initialization adds the assigned leaves. Reinitializing a child repairs
only that child, not an incompletely initialized sibling. Borrowing and moving
consult overlap with possible live loans. Assignments replace the target value's
origin set with the RHS reaching origins; joins retain origins from every
reachable definition. They do not search only the final expression's syntax.

Backward liveness includes explicit reads, pending argument uses, closure uses
and cleanup uses. A loan ends only when neither a live value nor a child loan
nor a pending implicit use requires it. Exclusive call reservations, when
supported, have explicit reservation and activation points; activation checks
all live overlapping child loans. Region constraints require origins to outlive
every use and escape destination. Return contracts describe which parameter or
global regions may reach results; storing into a longer-lived destination adds
the corresponding outlives constraint.

The solver processes reachable blocks in deterministic order with a bounded
worklist until no input or output changes. State comparison is semantic rather
than allocation-address comparison. The finite-height lattices guarantee
termination without an unbounded source loop expansion. Exhausted work/size
limits produce an incomplete-analysis error, never a successful certificate.
Unclassified core instructions and malformed CFG successors fail validation.

The abstraction relation requires every concrete initialized leaf to be within
`M`, every leaf in `I` to be concretely initialized, and every concrete origin,
loan, generation dependency and obligation to be represented by its possible
abstract fact. The local preservation arguments are:

1. A checked read/copy reads initialized typed storage; capturing contents
   preserves the value despite later source mutation.
2. A checked move consumes each source leaf once and transfers its dependencies
   and obligation, preventing subsequent reads or duplicate cleanup.
3. Initialization/assignment updates only the written leaves, after checking
   conflicts, and preserves untouched siblings and their obligations.
4. Borrow/reborrow permissions exclude conflicting accesses while descendants
   or retained uses remain live; shortening removes only capabilities with no
   future use in the graph.
5. A checked call preserves invariants assuming its verified modular contract;
   result/store/global effects conservatively retain every possible origin.
6. An invalidation has no live dependent safe access or implicit cleanup use;
   retirement cannot leave a safe capability to the retired generation.
7. Each executing exit transfers or discharges each required obligation once;
   CFG joins over-approximate all predecessors that can reach the operation.

These are written proof obligations for the complete design. The initial
implementation and finite tests establish only their explicitly exercised
subset. They do not prove that normalization, libraries, optimizers or native
execution satisfy this relation.

## Callable and trusted-boundary contracts

A checked function contract includes argument/result types and lifetime
relations, Copy/MoveOnly transfers, callable capability, retained origins,
global reads/writes, arena invalidation, cleanup retention, unsafe obligations,
observable failure and relevant SPMD control effects. Direct calls, aliases,
closures and indirect calls instantiate the same contract format. Recursive
SCCs solve effects to a fixed point; no callee-order assumption may hide a
transitive write. Unknown indirect effects conservatively include every effect
permitted by the callable type and reject requests for stronger guarantees.

Imported metadata must carry schema, body/build identity, target/cfg and
contract validity. A source body revision invalidates its previous certificate
and callers' derived summaries. Generated functions receive the same checking;
externs instead require explicit trusted metadata and boundary admission.
Safe globals remain supported through verified read/write effects, including
transitive and recursive calls; silently forbidding all globals would change
the language rather than implement its checking.

Unsafe implementations must establish their exported safe postconditions.
Assumptions include allocator alignment and non-overlapping live allocations,
checked extent arithmetic, correct native ABI transport, valid runtime
authority generation and synchronization, and machine transformations that
preserve permitted effects and failures. The wrapper audit ledger must record
preconditions, postconditions, trusted primitive identities and adversarial
evidence. Unresolved unsafe gaps cannot be marked audited-complete.

## Source-form normalization inventory

This table covers the `AstExpr` families at the revalidated base. All entries
are required production normalization work; the standalone core currently has
no AST normalizer. Existing source-unsupported forms continue to diagnose.

| Source/AST family | Required normalization |
| --- | --- |
| `Spanned`, `MacroExpansion`, annotations | Preserve primary span, definition and invocation chain; annotations supply checked type, not a new ownership operation. |
| `Literal`, `Var`, `TypeLiteral`, `BinaryData`, `Init` | Typed constants, place reads, static data or explicit initialization. Runtime type values retain existing admission policy. |
| `Binary`, `Unary`, `Cast` | Ordered operand temporaries and typed primitive operation; boolean short-circuit branches. |
| `Call` | Typed target, ordered captured arguments, explicit transfers/reborrows and instantiated effects. |
| `Let`, `Begin`, `Unsafe` | Fresh binding IDs, ordered initializers, lexical storage boundaries and value-producing tail transfer; unsafe context is explicit. |
| `Lambda` | Separate body, capture environment with explicit transfers, verified callable contract. |
| `Tuple`, `TupleRef`, `Array`, `DynArray`, `FixedMakeArray`, `MakeArray` | Ordered construction, allocation dependencies, typed component places and checked extents. |
| `ArrayRef`, `ArraySet`, `ArrayTake`, `ArrayPush`, `StringRef` | Explicit bounds/initialization operations, projections, mutation/invalidation and private bitmap semantics for `ArrayTake`. |
| `StructGet`, `StructSet`, `Set`, `Replace` | Resolved typed root/projection, single-evaluated destination, explicit assignment/replace transfer. |
| `Borrow`, `Box`, `BoxGet`, `BoxTake`, `BoxSet` | Borrow/reborrow, allocation, dereference provenance and explicit copy/move/mutation. |
| `If`, `Match` | Branches, discriminant refinements, fresh pattern binding IDs, joins and value result temporaries. |
| `While`, `ForOwnedState`, `ForOwnedStep` | CFG iteration and exits; generated iterator state/item transfers obey the same rules as authored bodies. |
| `WithRegion`, `WithEscape`, `WithScratch`, `InArena` | Arena generation/extent transitions, allocation context, escaping clone or result and explicit cleanup/invalidation edges. |
| `WithResource` | Typed owner initialization, retained cleanup operands, potential obligation and every scope-exit edge. |
| `Try`, `Return`, `Break`, `Continue` | Explicit propagation/return/loop edges and edge-specific cleanup. |
| `Foreach`, `SpmdReduce`, `SpmdScan`, `SpmdCompact`, `SpmdBroadcast`, `SpmdShuffle`, `SpmdProgramIndex`, `SpmdProgramCount`, `ForeachActive`, `LaneValue` | Preserve lane masks, uniform/varying types and divergence restrictions; check generated scalar/vector helpers against the same semantic transfers. |
| `PtrNull`, `PtrNullCheck`, `PtrAddrOf`, `PtrRead`, `PtrWrite`, `PtrOffset`, `PtrCast`, `PtrToInt`, `IntToPtr` | Typed raw-pointer primitives with admission/effects; never infer safe loan or dereferenceability from a machine address. |
| `StringData`, `StringFromBytes`, `ArrayData`, `ProgramArgc`, `ProgramArgv`, `ProgramEnvp` | Explicit trusted representation/entry primitives with their extent and lifetime obligations. |
| `CpuIdEax`, `CpuIdEbx`, `CpuIdEcx`, `CpuIdEdx`, `Xgetbv`, `Syscall` | Ordered primitive operands, canonical target/effect/failure classification. |
| `Comptime`, `Quote`, `Quasiquote`, `Unquote`, `UnquoteSplicing`, `BracketClause` | Check executable transformer bodies and normalize expanded executable output; quoted data is not executed; residual illegal forms reject. |

At declaration level, `DefFn` and executable `Def` initializers create bodies;
`DefMacro` creates a phase-specific executable transformer. `Test` becomes a
checked harness body. `ModuleBody`/`Module` and imports resolve identity and
contracts. Struct/enum metadata creates cleanup contracts and generated bodies;
dispatch declarations create callable contracts and implementation bodies.
Include declarations produce typed static inputs or checked comptime work.
An `Unsafe` declaration changes admission obligations without bypassing body
ownership checking.

## Entry points and feasible integration

`tc-check-fn-decl-body` is the first suitable adapter: it binds registered
parameter types, records expression types, checks the result type and then
starts consuming the type facts before calling the two AST ownership walkers.
Normalization must run in that consuming window. The current facts are cleared
at its end and synthesized expression IDs may miss the source-sized fact table;
they cannot be retained or treated as universally complete without changes.
`TcCheckedLetBindingFact` already distinguishes declaration ordinal, let body,
binding ordinal, name and initializer because generated/contextual AST nodes
may be shared. Preserve that occurrence distinction when creating normalizer
inputs. `tc-move-binding-type-id` currently reinfers annotated initializers and
can return an annotation or `i64` after a failed query; such compatibility
fallbacks cannot supply a new ownership certificate.

This is a producer change, not just a new consumer of the existing cache.
`tc-body-type-fact-record!` ignores an already recorded expression ID and skips
IDs outside its source-sized index. Context-directed paths can bypass the ID
recording wrapper. Consequently a successful cache lookup does not identify
the type of every contextual occurrence, and a missing entry does not imply an
untyped source error. A second `tc-expr` pass cannot repair this authoritatively:
`tc-check-fn-decl-scoped` explicitly relies on body checking being non-idempotent
and escapes the original diagnostic before scratch retirement rather than
rechecking to regenerate it.

The typed producer must therefore publish resolved occurrence results as part
of the successful inference operation. Each occurrence needs its resolved
binder/projection identity, contextual type, ordered child results and source
origin. Speculative typing must be transactional: discarded overload or
compatibility probes cannot become executable normalized nodes. The selected
result must retain the precise child occurrences actually chosen by inference,
including generated nodes; it must not join conflicting occurrence types by
AST ID. Tests need a shared generated AST node typed in two contexts, failed
speculation followed by success, and body/pool retirement before a retained
consumer runs. The producer described below is the one every checking route
now uses (see [Production cutover](#production-cutover-m5)).

`compiler_typed_occurrence.tl` now supplies the bounded transaction foundation
for that producer. Its caller-owned store retains canonical `AstType` values
within an explicit body lease, including types synthesized without a pool ID.
The lease pins the AST pools, a borrowed `InternCompatState`, and the resolver
namespace. Access checks the full body owner/generation/revision, pool identity,
and actual interner table/reset generation before touching leased payloads.
One mutable owner controls the store; shallow copies with independent counters
are outside its contract. Retire the store before any leased owner is retired.

Production resolver leases borrow the live canonical symbol and field-registry
containers. Each symbol map has a nonreused full-width owner and a shared,
checked mutation revision. Access compares the live owner before reading its
revision cell; stamps never retain a pointer into a retired captured map.
Replacement, removal, growth and declaration-table mutation invalidate leases,
including append operations; lookup-only access does not. The occurrence store
pins the captured stamps and declaration count, so refreshing a lease after a
mutation cannot authorize old records. Stores without a resolver cannot mint
resolved global identities. This does not yet provide a complete owned nominal
shape snapshot. Nested `AstType` payload consumption also needs the store-side
type-pool reset stamp before the aggregate normalizer can be enabled.

Typed handles include a monotonic serial as well as their body and slot.
Strictly nested attempts checkpoint every record/edge count; rollback never
rewinds serials or work, so slot reuse cannot revive discarded handles. Query
attempts may inspect existing results but cannot mint executable occurrences or
elevate to executable mode. Setup, provenance/literal bytes and operations are
bounded. Resource exhaustion latches a terminal body failure: it cannot become
an ordinary rejected probe followed by further publication, and retirement
remains available without allocation or payload access.
Production uses a growing store with small initial arrays. Every growth charges
initialization and live-row movement before allocation, moves the live rows,
and preserves their handles. Rollback retains capacity but refunds neither work
nor serials. This avoids a source prewalk and maximum-sized arrays per function.
Leased access also validates logical table extents against capacities and limits.
Child access rejects malformed spans using bounded subtraction before indexing;
an overflow-sized or negative span produces a structural error rather than an
array trap. Normalization can stay entirely behind the checked getter API.

Selected nodes retain ordered child handles, resolved binder/projection/call
identities, source origins and canonical literal values even when no source AST
ID exists. Every call retains the evaluated callee as child zero, including
calls with a known direct target; arguments follow in source order. The finite
operation enum has explicit shape rules and no permissive unknown operation.
Call registration checks its argument count against the canonical `Func` or
`CFunc` parameter list. The selected producer still owes instantiated argument
and result compatibility, coercion/reborrow choices, resolved projection
legality, capture/effect contracts and runtime evaluation semantics. This store
does not infer those facts from an AST ID or certify them from record shape.
These records do not by themselves validate ownership, perform inference,
construct control flow, or establish production admission.

`tc-check-fn-decl-body` now owns the selected store and full intern-state lease
before binding parameters. Inference returns its explicit type and root; the
existing scoped restoration and return, region, move and borrow checks run
once before a successful body reaches the selected consumer. The store retires
unconditionally before function scratch rewind.
The temporary installed-state bridge checks actual table and reset generation
against the context's explicit source session before allocating storage or
reading AST/type payloads. It never uses an unrelated installed table as a
source of identities or spelling. Full job-owned intern-state plumbing remains
necessary for the complete migration.

Each `TcBodyState` has a checked, monotonic full-width owner identity and a
non-refunded revision. Independently constructed contexts cannot alias an owner
through a shared interner or reused arena address. The canonical declaration
path traversal sets and restores its source path independently of optional
diagnostic observers. Captured ID inference validates this owner/revision,
source session, pools, store lease, and ID bounds before reading the expression.
Query bounds follow the canonical expression reader during macro expansion.
That reader uses stable segment storage, so distinct state-cell snapshots can
observe generated nodes appended through the live owner before a cursor is
published to the original context. A Query may observe that newer live cursor
only after matching expression storage, pool owner, and the context's explicit
source-session owner and generation. It does not publish or mutate the cursor,
and never treats unused capacity as initialized nodes. Existing macro phase
liveness still owns the backing storage; `AstNodePoolContext` has no separate
generation field. Capture instead requires the exact pinned reader/lease cells
and cursor, plus body owner/revision and source generation, before AST access.

`TcSelectedResult` returns the canonical inferred type, an explicit selected
occurrence or `Unrepresented`, and the linear `TcSelectedSink` on success and
failure. Contextual literals, unary operations, contextual binary operations,
`if`, `begin` and ordinary `let` use explicit selected
child results; their type-only entry points project the same implementation in
Query mode. A shared AST ID can therefore have distinct contextual occurrences,
and generated literals retain their canonical value without an AST ID. Plain
span wrappers forward the selected child while preserving its actual origin.
Unsupported and ordinary fallback paths preserve the original ID entry points,
including dotted-place normalization; they do not infer a second time to fill
the store. Failed or unrepresented parents roll back their selected children.
Lease, resource and identity failures remain hard errors. A `begin` gives only
its final child the contextual type. An early `Never` still checks the later
children once through Query and leaves the sequence unrepresented.

Unary operations and conditionals share the same implementation with and
without an expected type. Noncontextual binary inference returns both its
canonical operand types and chosen children; type-only operand clients project
that same result. This includes comparisons whose Boolean result supplies no
operand expectation. Literal-left narrowing retains a leased literal candidate
without typing it again. Its original RHS probe runs in a nested transaction:
the chosen narrowing branch commits that occurrence, while the fallback rolls
it back before the canonical contextual retry. Publication uses the successful
canonical literal type. Child order remains left/right even when the chosen
RHS was created first. Rollback preserves cumulative work and serials, and any
resource or identity failure remains hard.
Operand divergence likewise remains unrepresented pending an explicit selected
evaluation plan.

The same linear capability now owns a body-leased binding association table.
`tc-type-env-scoped-carrier-bind-params` records each parameter's resolved type
and exact slot coordinate at its successful canonical binding event. The
completed, uniquely owned carrier is moved into the runtime and checked against
the pinned environment store, scoped state and lookup epoch. Ordinary variable
policy uses `tc-var-binding-after-local-field-check-mode`; its type-only wrapper
projects the same result. A selected read retains that actual winner rather
than looking the name up again. A contextual coercion that changes its type
remains unrepresented until an explicit coercion occurrence exists.

The table uses the canonical slot ordinal only to index bounded, lazily grown
storage. Full owner/epoch/generation validation still determines identity;
indices are not packed keys or source IDs. Growth and copying are charged before
allocation, and lookups do not scan all parameters. Failed occurrence attempts
restore the visible association bound without refunding work. Marker slots,
unmapped persistent/cache winners and other carriers cannot acquire binder IDs
from this table. `tc-infer-selected-let-init-at` is the one canonical initializer
checker, and `tc-let-binding-apply` performs the existing annotation, resource,
reference and checked-transition checks once. The selected binding event follows
the actual value slot, after owner/phase markers, and retains an `Initialize`
child before checking the next initializer. Initializer origins come from the
selected child through lease-checked getters, with byte-copy work charged in
advance. A let retains the ordered initializations and body in a sequence.
Scope exit restores the actual carrier and visible association bound without
discarding the binder records used by that sequence. Specialized capability
closures and unrepresented initializer coercions still preserve legacy admission.

The occurrence store also has a separate typed-place table. A root names a full
binder handle; a projection names its exact parent and resolved projection
handle, with matching canonical container/result type handles and a checked
source-origin handle for that projection step. Place identities
participate in the same bounded growth, nested rollback and nonreused serial
rules as values. `FormPlace` produces a distinct Place category and retains
index-value children in root-to-leaf evaluation order. It does not read the
aggregate's contents. `CopyPlace` and `MovePlace` produce values from that exact
formed-place child; scalar operations cannot consume a Place category as if it
were an aggregate value. These are representation and identity checks, not a
Copy eligibility, initialization or loan certificate. The initial source place
producer follows lexical roots, static tuple projections and owned fixed/dynamic
array projections through the actual
canonical binding winner. It retains the typed path without a whole-aggregate
read, then chooses `CopyPlace` or `MovePlace` from the resolved component type's
canonical Copy classification. Array indices use canonical contextual inference
once, preserving receiver/index checking order and selected index-child order.
The eventual checked place consumer must interleave each index evaluation with
that projection's access and bounds check before evaluating the next index;
eagerly evaluating every index first would reorder observable failures. Borrowed
array/Slice receivers, divergent indices and other receiver forms keep their
canonical typecheck and remain explicitly unrepresented. Aggregate construction
and product normalization are still required; the scalar normalizer explicitly
leaves place acquisitions unsupported.

Canonical field lookup now returns the resolved result type together with the
actual winning declaration index and field ordinal. Region/reference wrappers
preserve this result, while compiler metadata fields explicitly have no nominal
identity. Existing type-only callers project that one result. Selected
`StructGet` place publication, lazy complete field-shape capture and the
corresponding product consumer remain unfinished.

`tc-lookup-visible-binding-id` retains assignment's actual winner through the
existing module-selection and import-ambiguity policy; type-only callers project
that same result. `tc-infer-selected-set` selects this target before checking the
RHS once and retains it across RHS-local shadowing. Cleanup, region and reference
checks still precede `Assign` publication. Persistent/global targets remain
unrepresented until their contracts exist, and identity failures cannot fall
through to another lookup.

`tc-infer-selected-return` owns the canonical operand inference and cleanup escape
check. The public inferred type still follows contextual `Never` coercion; the
selected `Return` occurrence retains intrinsic `Never` and its explicit operand.
`tc-selected-publish-flow` derives the intrinsic result of selected sequences and
conditionals from their checked child records, preserving this distinction
through `let`, `begin` and `if` without retyping. Divergent binary operands,
initializers and assignment RHSs remain explicit migration gaps; their parents
discard retained children and preserve the original typechecking result.

This first slice deliberately returns `Unrepresented` for unsupported forms,
including expansion/unsafe wrappers, and for synthetic clients without a real
source origin. It does not fabricate locations or reject previously accepted
source for those migration gaps. `tc-selected-consume-body` remains the
validation-only anonymous-body hook. Named function bodies use
`tc-selected-prepare-named-body` while the lease is live: normalization and the
core checker are the only ownership authority. Typed identity, structural and
core failures are hard errors, and since the cutover so are Unsupported and
Resource failures (E0211); no legacy region/move/borrow check remains to
select.

The compile route records every certified named body in a job-owned registry.
Each entry has the full selected body owner/generation/revision, declaration
module/name and expression identity, pool/interner identities and a type-pool
stamp; lowering looks every body up and rejects a missing or stale entry.
Append-only pool growth preserves entries; reset and retirement invalidate
them. An entry's `Legacy` route means the ordinary lowerer emits the certified
body from its AST; it is a lowering route, not an ownership verdict. Named
clone declarations appended by the checked clone handoff receive explicit
`Legacy` entries.

The MIR-to-IR emitter (`compiler_ownership_lower.tl`), its exact source
witness and the retained normalized bodies were removed at the cutover: the
route covered only primitive scalar bodies and was disabled. Lowering from the
ownership MIR instead of the certified body's AST remains future work and
would retain the selected facts per body again. The scalar source fixture runs
at opt0/1/2 through the ordinary lowerer.

The concrete producer boundary spans both `tc-expr`/`tc-expr-id` and
`tc-expr-with-expected-or-actual-core`/`tc-expr-with-expected-or-actual-core-id`.
The ID forms normalize dotted places and have direct variable/assignment fast
paths; the value forms also accept synthesized expressions without pool IDs.
The call-argument policy and direct thread-spawn lambda path must produce the
same kind of result. Hooking only the ordinary ID wrapper misses contextual
children and these direct paths.

Completing source integration requires extending these owning API changes:

1. Extend the selected expression-inference result carrying the resolved type
   and an occurrence handle to the remaining forms. Keep pure type operations and query-only clients
   on type results. Expression-producing helpers must return their selected
   child handles explicitly, including evaluation order, rather than infer
   children from the order in which type queries happened. Metadata wrappers
   preserve source and expansion provenance without duplicating evaluation.
2. Give each body a builder with nested attempt checkpoints. Failed or
   abandoned alternatives discard their occurrence output; a selected result
   retains only its chosen children. Query-only inference cannot publish an
   executable occurrence. Occurrence transactions do not by themselves undo
   existing typechecker or AST mutations: their existing scope restoration and
   mutation journals still apply. Do not replay inference to populate a gap.
3. Retain resolved identities where they are available. Parameter, let,
   pattern, resource and loop binding producers allocate body-local binder
   IDs; variable resolution returns the selected binder or global contract.
   Parameters, ordinary lets and variable reads now retain this identity through
   `tc-var-binding-after-local-field-check-mode`; the legacy wrapper projects
   only the type. `tc-struct-field-type-id` still resolves a
   registry handle before returning only the field type. Preserve the resolved
   projection and its instantiated type there. Generic `tc-bind-id` also binds
   checker markers, so it is not by itself a semantic binder producer.
4. Make argument checking return a checked call plan. In
   `tc-check-call-args-with-message-at`, each final argument has its selected
   auto-borrow expression, contextual type and matched formal; these are
   currently discarded in a unit result. Lifetime discovery and the
   `tc-call-arg-expr-type` memo are preliminary type queries, not authoritative
   executable children. Retain the resolved callee, final argument occurrences,
   instantiated signature and coercion/reborrow operations together.
5. Finish the body result inside `tc-check-fn-decl-body`, then transfer its
   owned types, origins and occurrence storage before
   `tc-check-fn-decl-scoped` or `tc-check-decl-scoped` rewinds scratch. A neutral
   snapshot cannot retain unowned `AstType` payloads or pool-local integer IDs.
   The job-owned checked result must distinguish completed bodies from partial
   declaration recovery. `tc-check-decls-with-paths` currently permits summary
   prefix reuse without body observations; capture requires a cold walk until
   validated body contracts can be retained and reused.
6. Use that lifecycle for globals, lambdas, transformer bodies and REPL
   expressions as well as named functions. A lambda has a separate body and
   capture contract, not merely more instructions in its enclosing body.
   Generated bodies appended after typechecking require their own admission.
   Preserve the result across frontend pool retirement and require its exact
   body/revision identity at lowering.

Lexical production obtains provenance from the actual winning lookup.
`tc-lookup-binding-selected-id` now owns the shared scoped winner used by
ordinary and unsafe-aware type projections. Assignment's visible-name route
retains that result through its module-selection policy. Looking up a name
again after inference is not a binding identity. A scoped slot index and its
generation are insufficient: two stacks start with the same coordinates.
Capture must pin the owning environment store, scoped state and stack lookup
epoch, and associate a slot's generation with a `TypedBinderId` only at an
actual successful parameter or local binding. Marker slots and unmapped
persistent/cache winners remain unrepresented in this bounded slice.

The scoped carrier must also be the actual runtime-current mutable carrier.
An internal shallow copy made before binding can reuse the same state, epoch,
index and generation independently; a saved carrier is not a second mutable
owner. Restore increments the current cache generation, preserving retained
outer slot generations and distinguishing reused inner slots. Both generation
and epoch advancement now use sticky exhaustion states. Canonical lookup and
source inference reject exhaustion before cached results, including exhaustion
caused by restoring a scope after an otherwise successful check. Occurrence rollback restores the visible binder associations
alongside the canonical scope rollback, without refunding serials or work.
An early `Never` expression in `begin` is another migration boundary: current
inference still checks later expressions, so the bounded producer retains
that checking exactly once while leaving the whole unsupported sequence
unrepresented until explicit unreachable child handling exists.

Scalar `while`, `break` and `continue` now have selected producers. Query and
Capture call the same condition/body inference and canonical type checks;
conditions are checked before installing the body's loop target. Capture
restores both the marker and visible binder associations on success or error.
Only the actual chosen condition/body occurrences become the structured While
node. An unsupported child discards the parent attempt; it is never queried a
second time to recover an occurrence. The primitive normalizer maps represented
loops and exits to the same ownership CFG. Since the cutover every well-typed
expression has a selected producer, so no loop is left Unrepresented.

Existing inference alternatives make transaction tests concrete:

| Producer/probe | Occurrence hazard |
| --- | --- |
| `tc-binary-expr-with-expected-or-actual`, `tc-unary-expr-with-expected-or-actual` | Contextual children may succeed before the operator rejects that typing and retries ordinary `tc-expr`; discard those earlier child results. |
| `tc-spmd-reduce-init-value-type`, `tc-spmd-reduce-type-from-value` | Init-guided typing can fall back to value-guided typing. The latter queries the value before the init, so query order cannot define runtime operand order. |
| `tc-call-target-expr`, `tc-call-target-expr-id`, `tc-direct-lambda-check` | An unsafe direct target can retry after ordinary value rejection; direct lambdas use a separate capture policy. Retain only the selected target result and its policy. |
| `macro-check-ordinary-operand` | Its dotted-place mutation journal is restored even after successful checking. This check constrains captured syntax; it does not make that syntax a runtime occurrence before expansion. |
| `tc-expr-discarding-errors`, `macro-captured-expr-produced-type` | A successful speculative query can provide a captured type while its error is otherwise suppressed. It cannot publish a runtime body or ownership success. |
| `tc-check-defmacro` | The placeholder CTFE run can fail without rejecting the macro definition. Transformer checking, placeholder probing and the expanded executable output have distinct phases and admission results. |

This change produces authoritative typed input, not a normalized checked body
by itself. The source normalizer, control-flow construction, ownership analyses
and verified lowering handoff below remain necessary before production cutover.

A reusable implementation should have an AST-independent graph/core module,
an AST normalizer with a neutral typed-input snapshot, and a small typechecker
adapter that supplies resolved expression types, bindings, projection types,
call contracts and source origins. Importing `compiler_typecheck_core` from a
normalizer that the typechecker imports would create a dependency cycle.
Alternatively the adapter can build the graph inside the typechecker while
delegating all ownership decisions to the core. In either arrangement:

1. Resolve binders to fresh body-local IDs while traversing lexical scopes.
2. Snapshot or query already checked types in the correct pool; explicitly
   create typed synthesized nodes, with no silent fallback on absent facts.
3. Emit blocks and explicit value temporaries, including wrappers and exits.
4. Validate structure, solve semantic analyses and publish a revision-coupled
   success result only when every required analysis succeeds.
5. Lower that checked body or consume a verified mapping of its transfers;
   do not re-decide ownership from the original AST.

| Production route | Current path and migration gap |
| --- | --- |
| CLI check and package/dependency check | `compiler_check_core.tl` uses the public checked API; declaration bodies can converge at the common hook. Prefix/import reuse needs validated ownership contracts. |
| Build/run, batch, reusable drivers, assembly/object/PIC and package runtime | `lower-typecheck-clone-and-lower-with-source-names-and-intern-state` calls the specialized checked API; checked body admission must survive compaction and all backend routes. |
| Inline tests and documentation tests | Generated harness functions must enter the common body path, including cfg/macro variants. |
| LSP and semantic index | Shared checked declaration results must govern acceptance. Speculative expression type queries may supply editor information but cannot publish ownership certificates. |
| REPL | `typecheck-compiler-repl-expr` currently checks declarations and then calls `tc-expr` directly for the expression. Wrap the expression as a body and consume full checking before evaluation. |
| Source/native comptime and macros | Check executable transformers before execution and check expanded Expr/Decls/Module bodies afterward. Phase and pool ownership must accompany the contract. |
| Lambdas and global initializers | Today lambdas are visited inside AST walkers and globals have a separate move-initializer path. Give each an explicit body and appropriate environment/result contract. |
| Generated Clone helpers | Lowering explicitly treats appended clone declarations as trusted compiler output and extends only signatures. They require checked bodies or a verified closed-template admission contract. |
| Generated cleanup, dispatch and SPMD functions | Inventory each synthesis site and check its typed semantic operations before ABI lowering. |

The first source vertical slice should cover literals, parameters, lexical
bindings, nested aggregate places, assignment, moves, branches, scalar loops
and all exits. It must be a complete normalizer/checker/lowerer path for its
stated surface, with positive and negative twins. It is not permissible to turn
that experimental subset into a production fallback: during comparison,
unsupported new-path cases are reported as incomplete; at production cutover
every currently supported safe construct must have a checked rule.

## Checked lowering, storage and diagnostics

A checked body handoff needs body-owner/revision, structural validity, completed
analysis set, contract dependencies, source provenance and an exact lowering
input identity. Structural validity alone is not semantic acceptance. The
lowerer must reject a missing, foreign, retired or stale handoff. Removing
regions or deciding sret and by-value parameter storage occurs afterward.

The lowering simulation obligation is that every machine operation either
implements the next semantic step or is an unobservable implementation step.
Aggregate copies cannot alias source storage when value semantics require a
copy. Earlier scalar arguments must snapshot before later mutations. Enum
payload addresses cannot substitute for payload values. Conditional cleanup
uses checked initialization facts, and invalidation ordering preserves all
remaining uses. Backend frame slots, register widths, FFI layout and sret
roles remain independently verified physical obligations.

Core IR and facts use a dedicated phase arena with an explicit consumer
lifetime. Body-local data may be retired after facts and source origins have
been transferred to their consumers. Retained data must own copied paths/types
or a pinned pool authority; a raw AST/intern ID cannot outlive a pool install,
reset or scratch rewind. Reusing the driver's checked-pool begin/finish
boundaries avoids a second independent ownership protocol. The existing
pointer-proof input's owner/revision and fail-closed handoff design is relevant
infrastructure, not a replacement ownership certificate.

Retained canonical type facts use `AstTypePoolStamp`: the actual state-cell
identity, owner arena, segmented-storage identity, non-reused revision and
captured prefix length. Append-only growth preserves a stamp. Truncation,
replacement and retirement invalidate it. Shallow views share a revision cell
and append high-water mark, so an older view cannot overwrite a newer suffix
while retaining its former evidence. A types-only copy has a new identity;
transferring facts requires checking the copied prefix and issuing a new stamp.
Validation compares against a currently live context before reading its types;
it never dereferences an address taken from the stamp. Job ownership still
governs the lifetime of that live context. This type stamp does not establish
interner ownership, which must be checked separately for nominal type names.

Diagnostics retain the offending operation span, its original macro invocation
and definition chain, the conflicting move/loan/owner span, and the applicable
call or cleanup edge. Dumps use stable dense IDs and deterministic traversal;
host addresses and allocation order must not affect observable output.
Malformed-ID, projection, signature, scope or successor diagnostics identify
the body/block/operation and its source origin where present.

## Evidence, limits and retirement

The independent model must enumerate concrete executions of a small core and
derive expected abstract behavior without calling production transfer code.
Shared parsing/serialization is acceptable; shared acceptance logic is not.
Finite tests cover join laws, monotonicity, transfer over-approximation,
determinism and identity round trips. Counterexamples are failures, including
cases where a valid operation is rejected; no filtering by compiler result is
allowed. Its supported operations and exploration bounds must be printed with
the result. This is bounded executable evidence, not a universal proof.

The first [independent model](../tools/ownership-model/README.md) has four
concrete initialization leaves, six places, sixteen concrete stores and 82
abstract states. Its 460,800 branch/loop/exit graph combinations explore all
reachable concrete states to a fixed point with an explicit 32-round limit.
Read, Move, Initialize and Invalidate apply to non-Copy leaves; production's
Copy-preserving Consume/Move behavior is a separate core regression. Model
mutations cover lost moves, an unsafe join, omitted cleanup uses and dropped
backedges. This model checks its abstract semantics against independently
written concrete rules; it is not itself evidence that the production source
normalizer or compiler core matches every modeled operation.
The separate `crosscheck.tl` adapter compares 2,916 production transfer cases
and 28,800 production CFG cases with concrete-model expectations. It rejects
unexpected structural/resource failures and checks successor readability as
well as rejection. The transfer count includes 972 comparisons of moves
between ordered disjoint scalar source/destination places, in addition to
the 1,944 single-place cases. Three isolated production mutations must detect
a retained Consume source, a retained Move source and an intersection used in
place of the possible-state union. `scripts/verify-ownership-model.sh` requires both programs
at all three optimization levels with exact counts, input identities and
resource reports; only a completed passing campaign establishes that bounded
production correspondence.

Production migration evidence additionally requires normalized dumps for
equivalent source spellings, authored positive/negative twins, generated
control-flow/loan/cleanup/arena interactions, runtime results derived before
compilation, and deliberate mutations. Rejection requires a normal,
source-located semantic diagnostic for the intended operation. A crash,
timeout, OOM, stale artifact, unsupported route, unrelated parser/import error
or unexecuted case is a distinct failure, never a successful rejection.
Replay records need source/compiler identities, target/cfg/optimization and
comptime mode, model version/bounds, commands and actual observations.

The optional `compiler-arena-sanitizer` build calls the exact runtime hook
`tl_arena_sanitize_enable`. Its statically selected Linux/Windows runtime
templates have distinct catalog identities; disabled templates retain their
original bytes. Destroyed mappings remain reserved until process exit, with
resident pages discarded and access disabled. Rewind seals a segment at the
exact mark, forcing future allocation into a fresh segment. Its whole retired
pages become inaccessible; its partial page shared with the live prefix is
poisoned without reclaiming the live prefix. These are bounded test workloads:
virtual reservations accumulate even though committed payload is released.
Ordinary arena header counters describe the remaining allocatable prefix,
not the process's quarantined virtual reservations.

`tests/integration/arena_sanitizer.tl` distinguishes expected hardware faults
from valid execution and persistent partial-page poison, including later
allocations, repeated rewind and arena destruction. These intentionally invalid
runtime probes are not source-language semantic-rejection tests. The independent
allocation/provenance model additionally covers readable invalid pointers and
suballocation bounds. A partial-page stale scalar read need not fault, and an
expected value can equal the poison byte; neither poison nor page protection
establishes full provenance or catches every invalid access. Frame/ABI checks
remain separate.

### Measured cost against main (12 October 2026)

Generated code (cachegrind Ir, `scripts/check-instruction-counts.sh`, TypeLisp
rows, which reproduce across hosts; main = e10dcb268's baseline):

| Benchmark | Main | This branch | Delta |
| --- | --- | --- | --- |
| hashmap_grow | 1,319,080 | 1,639,253 | +24.3% |
| ssa_construct | 648,800,844 | 794,148,804 | +22.4% |
| regalloc_greedy | 569,466,453 | 645,269,909 | +13.3% |
| cfg_domloops | 560,759,115 | 634,883,034 | +13.2% |
| callgraph_scc | 470,599,782 | 530,360,048 | +12.7% |
| gvn_table | 712,980,999 | 802,794,067 | +12.6% |
| opt_bytecode_vm | 712,000,791 | 772,000,848 | +8.4% |
| opt_quicksort, intern_table | | | +7.9%, +7.8% |
| spmd_mask | 8,613,460,698 | 9,234,170,963 | +7.2% |
| hashmap_get, liveness_scan | | | +6.4%, +6.1% |
| asm_render, hashmap_churn, peephole_lines, hashmap_insert, sccp_lattice | | | +2.6% to +4.0% |
| spmd_reduce | | | +0.35% |
| spmd_map, spmd_short_tail, spmd_zip, string_scan, arith_loop, array_sum, lex_source, opt_crc32, pure_call_join, loop_call_literal, borrowed_disjoint_store | | | within +0.004% |
| read_sexpr | 725,455,657 | 721,908,422 | -0.5% |

Two causes account for the regressions. First, an element store captures its
place before its value (SPEC 5.10), which put the destination address in a
register across the value and kept the unroller's word-merge tier (K=4) from
seeing a pure word body; lowering now forms a scalar element's address at its
store, `store_addr_sink` sinks a single-use address gep next to its store, and
the word-merge tier accepts a zero-offset gep as an address alias (spmd_map went from +57.8% to within 0.001% of main, spmd_mask from +28.6% to
+7.2%, opt_bytecode_vm from +20.2% to +8.4%). The
rest traces to inlining: aggregate snapshots (#7900/#7901) and operand captures
(#8433) are scalar-replaced at opt2, but the checked inliner prices callees
before that, so the modelled saving of a merge main kept (hashmap
`insert-ref!` into its driver: 183 against a boundary of 72) exceeds the
window's plausibility cap and the merge is reverted; ssa_construct also loses
the LGA specialization that followed main's inlining. Pricing callees after
their own scalar replacement is the follow-up.

Compiler instructions for the opt1 self-compile (`compile src/main.tl`, each
compiler on its own tree): main 69.3G (its baseline row), this branch 177.3G
(2.56x).
The largest single costs are typed-store lease and shape validation on every
access (`typed-lease-ok` 8.8G, `typed-count-valid?` 4.0G, revision and lease
checks about 5G more), the ownership core's loan conflict walk (about 3G) and
repeated type classification (`holds-reference?` family, about 4.5G); the rest
is spread across the producer, normalizer and core. GitHub Actions gates this
row at 0.5% and only refreshes it there. Stripped stage2 is 9,945,400 bytes,
54,600 under the 10,000,000-byte cap.

Compiler scaling (`scripts/check-compiler-scaling.sh`, marginal instructions
per added declaration, CFG node, struct field or macro expansion) rose with
the per-body checking: under `check`, 95.7K to 356.8K per declaration, 107.2K
to 721.8K per CFG node, 241.5K to 595.4K per field and 1.15M to 1.45M per
expansion; opt1 and opt2 rows rose by 1.16x to 2.6x. Growth stays linear
(1.10 or less on the rows main measured as linear), and no row turns
quadratic. perf/compiler-scaling-budgets.tsv holds the refreshed rows.

Baseline and changed-source cost measurements must use identical workloads and
record instructions, wall time, peak live memory, virtual reservations, compiler
size and CI cost. Full instrumented self-host and native-comptime acceptance
requires the final compiler and canonical gate results; focused experimental
checkpoints do not establish production cutover.

The cutover retired the authoritative `tc-move-check-*` and
`tc-borrow-check-*` walks and the legacy lambda capability walk (Production
cutover, above). Definitions that keep the `tc-borrow-*`, `tc-move-*` and
`tc-moved-*` prefixes are place typing, diagnostic text shared with the
graph's messages, and state the typechecker still threads; none decides a move
or borrow verdict. Source/entry-point, seed-regression, unsafe-wrapper,
mutation, instrumentation, performance and target-route evidence accompanies
the pull request that lands this work.