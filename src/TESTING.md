# Selfhost compiler testing

`ssa-indexed-label-links-preserve-newest-first` checks label heads, interleaved
phi links, capacity growth, missing labels and renamed-block logical positions.
The optimizer smoke's `dense-storage` test also checks edge captures before
rollback, independent sibling versions, missing predecessors and unbound
candidate variables. Keep both entry points when changing SSA storage; the
fixed-source compiler/benchmark and CFG scaling comparisons require complete
SSA IR (including value numbering) and raw assembly equality.

`mut_borrow_field_writeback` checks immediate mutable field call arguments at
opt0/1/2 on both hosts: one/two-word locals, nested and disjoint fields, narrow
and SSE fields, later sibling effects and repeated calls. Writeback merges only
the borrowed field into the current local. Shared borrows, whole-local
writebacks, memory-backed receivers and reference receivers remain controls;
the safety corpus retains overlapping-place borrow rejection.

`nested_mut_borrow_pointer` and `nested_mut_borrow_receiver` require exit 5
at opt0/1/2 on both hosts: nested call borrows lend original inline storage
from memory-backed locals and mutable-reference receivers.
`nested_mut_borrow_storage` covers deeper/nonzero-offset projections, narrow
and floating fields, fixed/dynamic arrays, tuples, boxes, reference-valued
fields, single index evaluation, non-call borrows, memory-class globals and
shared reads. Keep register-local call writebacks covered by
`mut_borrow_field_writeback` alongside them.

`global_mut_borrow_field` requires exit 5 at opt0/1/2 on both hosts for a
mutable call borrow of a two-word global's field. `global_mut_borrow_storage`
checks one/two-word globals, disjoint and repeated writes, narrow/SSE/pointer
fields, original-slot identity, shared reads and unit-tail borrows,
and nested memory-class globals. Global fields lend their existing storage;
register-local call borrows retain their separate writeback path.

`compiler-lower-unit-field-reads` requires canonical unit results without
addresses, loads or packed-word extraction for zero-sized fields on both ABIs.
`unit_struct_fields` exercises empty, one/two-word and memory-class structs,
nested empty fields, checked/raw references, owned/borrowed destructuring,
receiver effects and unit equality/inequality effects and early exits at
opt0/1/2. Keep the separate
unsupported tuple/array ABI checks.

`backend-packed-literal-records` checks the physical byte and relocation contract
for immutable literal pools: empty/singleton, independent and competing owners,
suffix chains, input permutations, interior NUL, UTF-8 and larger collections.
Every input retains exact bytes plus its terminal zero and an aligned pointer/length
header after the input arena is destroyed. The backend smoke runs the same checks;
mutable binary constants keep independent storage. Assembly and direct objects
consume the same literal records. `packed_string_literals` compares complete
native stdout for suffixes, competing owners, repeated, empty and UTF-8 literals
at opt0/1/2 on both hosts.

`stdlib/tests/process_argv.tl` covers the Windows encoder's exact Microsoft C
argv goldens and byte limit, both native spawn modes, and all 4096 public
arguments. Keep empty/tab/quote/trailing-backslash cases and exact framed
child output. Windows text and direct-object startup must decode the same
rules, preserving program-name quoting separately; update their existing
executable-template payload and ordered-event identities together.

`cse-block-tables-keep-the-first-walk-state` installs address-taken facts for
its own blocks before the raw CSE walks. A retired preceding function's facts
must not be read. Keep the empty-state, generation and repeated-expression
assertions when changing this fixture's setup.

`stdlib_math_table_payloads.tl` hashes every word of the 15 private math tables
in little-endian order against independent SHA-256 pins at opt0/1/2. Its length
checks cover all 1,290 words and empty/zero/max-word construction; the existing
exp fixture also retains its 128 individual tail-payload comparisons. The
`math-table-literal-errors` CLI case rejects floating literals and runtime
values in the literal-only array helper. Its two native transformer identities
replace the old row/table builders without lowering the native-entry floor.
Math codegen cases require static table definitions and reads while retaining
allocation, external-call and instruction exclusions.
The six scalar math fixtures retain their batched default cases and also run
explicitly at opt0/1/2 on both hosts. The public test transcript runs every
math inline test at each level through the native host toolchain.

`spmd-helper-stack-parent-snapshots` pins empty/single/dense pushes, growth and
restoration without leaving completed siblings active. The existing traversal
isolation test preserves job/scratch ownership. `spmd_inline_helper_composition.tl`
compares composed arguments, repeated callees, imported bodies and masked tails
with ordinary calls; safety rows keep direct and mutual recursion rejected.

`git-object-tree-linear-names` and `git_object_smoke` check canonical Git tree
order, separated file/directory duplicates in both object-ID formats, and
exhaustive short sequences against the former all-pairs duplicate rule. Exact
comparison budgets cover 10,000 entries and nested prefix stacks; the budget
counts duplicate look-back work, with at most twice as many comparisons as
entries. Keep the byte/entry limits and malformed-object coverage at opt0/1/2
on both hosts.

`tc-dotted-alias-variant-source-name-boundary` checks absent source names,
sentinels, the source-table boundary and structural pair/triple/fresh-local IDs
through both alias fallbacks. A missing structural variable must retain E0201.

`type-resolution-list-order-and-allocation` checks empty through wide lists,
mixed concrete/resolved/generic elements, immutable input and nested function
and tuple types. Run it with `--cfg compile-profile` at opt0/1/2 to check linear
allocation with live counters. The adjacent pool-isolation test also resolves a
list while a different compatibility pool is installed.

`load-cse-runtime-global-argument-needs-installed-row` covers all seeded fill
helpers with same/different global destinations, global addresses, zero counts,
missing arguments, absent tables and cells-only/object-only availability.
`global-mod-ref-installed-zero-row` distinguishes a missing row from an installed
empty write set and an unavailable table. Keep the T2-2
same-global rejection and unrelated-global forwarding controls beside them.

`compiler-ast-span-forwarding` runs the compaction fixtures with source-span
consumption enabled: empty input with a populated destination, small and odd
live tails, pool-segment boundaries, unreachable source suffixes, shared
expressions, reordered canonical/ReSpan views, destination reuse and spans read
after source destruction. Nonconsuming cases preserve source provenance. Test
builds poison the consumed source's shared span-base table so later reads
through any context view fail; full compiler and corpus builds with `--cfg test`
exercise the finalization-to-retirement boundary.

The `tc-read-value-*` tests retain unchanged expression IDs and cover every
result-path wrapper, empty sequences, conditional/match arms and non-result
children. The owner test crosses an expression segment boundary with colliding
IDs in a current peer, then destroys both that peer's node storage and base
arena before reading the new payloads. Keep the shared `BoxTake` occurrence
test: its prefix stays owning while its result becomes `BoxGet`. Run these at
opt0/1/2; restoring allocation for unchanged nodes, suppressing the real read
rewrite or allocating payloads in the current peer must fail the regressions.
Unchanged paths check allocator deltas as well as row counts. A mixed Match
case keeps the earlier arm unchanged while rewriting a later arm.

`backend-forwarded-address-*` tests coalesced copies and same-type casts on
both targets, phi filtering and cycle scheduling, and final-IR branch loads
whose address setup must survive. Initialized same-home copies and real swap
cycles remain controls. `forwarded_addr_loop_argument.tl` and
`forwarded_addr_loop_callee.tl` exercise both edges of a loop-carried address
phi at opt0/1/2 on both hosts; explicit source snapshots isolate these cases
from the separate lowering and stale-load bugs.

`linker_coff_import_reader_tests.tl` shares its assertion body with the native
opt0/1/2 smoke. It checks LLVM and Microsoft SDK member fixtures, all admitted
kind/name modes, literal IAT names, hint/ordinal boundaries, byte round trips,
every truncated prefix, malformed strings/headers, bigobj classification,
resource boundaries and stable normalized/diagnostic dumps. Normal tests run
neither producer tool. Preserve physical member IDs, original spellings and
timestamps separately from normalized identity when adding cases.

`regalloc-move-index-direction-and-strictness` pins directed admission,
undirected duplicate suppression and newest-first strict upgrades.
`regalloc-move-index-growth-and-reference` compares every slot with the former
list-scan semantics through mixed insertion modes, full-width signed IDs,
table growth and interleaved builders. `regalloc-move-index-hash-collisions`
checks real pair-hash collisions, an absent pair at the chain tail and
strict upgrades through colliding entries. `regalloc-move-index-prefix-promotion`
pins the exact small-list boundary, one-time promotion, duplicate/self moves
that must not promote, and strict upgrades across promotion. Run these at
opt0/1/2, retain the dense sequence contract tests, and compare fixed-source
compiler, benchmark and CFG scaling assembly when changing move indexing.

`compiler_macro_diagnostics.tl` checks macro namespace, operand/output, depth,
author-error, evaluation and fuel codes, preserves nested parse/typecheck codes
and E0218, and carries rich nested frames through a later compiler job. Run it
at opt0/1/2. The safety corpus observes every new code through `check` and pairs
an unfinished generated-macro table cycle with an accepted ordinary import
cycle. The dependency TLCI surface gate checks E0505/E0507 on both native and
forced-source routes, retaining its exact route and cross-file attribution
checks on Linux and Windows. The registry and parser smoke cover parse-code
round trips and complete `explain` entries.

`linker_ar_dialect_reader_tests.tl` compares GNU `ar`/`ranlib`, LLVM GNU/64-bit
and BSD archives against recorded `ar tO` and `nm --print-armap` oracles.
The internal test runs no external tools. It checks duplicate/empty/byte names,
ordered duplicate symbol hints, BSD sorted and extended index names, both BSD
byte orders, odd payloads and internal alignment padding. Every byte offset of
the GNU fixture is tried as an index target; only ordinary member headers pass.
Every incomplete structure in six small 32-/64-bit index layouts is rejected,
including repacked payload truncations with otherwise valid target offsets;
the signature-only empty archive remains valid.
Keep the exact-limit/one-below cases for all `ArchiveLimits` resources, unsigned
overflow diagnostics, malformed names/tables, special ordering and stable
input/revision identities. Run the suite with a fresh compiler at opt0/1/2;
the complete inline suite runs the same cases on Linux and Windows.

This guide describes the testing convention for compiler-facing TypeLisp code
under `src/`. The self-hosted compiler is built in layers, so tests
are also layered: keep each case at the lowest layer that proves the behavior,
then add runnable or end-to-end coverage only when that extra boundary matters.

`compiler_tlci_native_producer_tests.tl` interleaves independent parsed macro
captures with colliding expression/type and intern IDs under an installed decoy.
It compares complete generated source and unsupported-body reasons with each
owner's serial result, resets one source owner, and keeps its peer and the decoy
unchanged. Result-kind tests distinguish equal IDs in different interners and
missing sentinels. `compiler_tlci_native_source_owners.tl` runs the same assertions
through the native corpus at opt0/1/2 on both hosts. Keep full-catalog source
parity, all native macro entries and existing backend/image gates when changing
the source-owner boundary.

`compiler-optimize-bitwise-width-self-test` checks narrow constants with wider
bitwise masks and high bits, commuted operands, minimum signed values, narrow
results and unknown operands. `packed_narrow_bitwise_fold.tl` exercises negative
i8/i16/i32 fields in one-word layouts across calls at opt0/1/2 on both hosts,
with smaller memory-storage layouts and zero/positive field values as controls.

`regalloc-tail-stack-forward-homes` and `backend-tail-stack-forward-registers`
compare stack tail fallbacks with ordinary calls on both ABIs. The overflow
boundary test checks twice each GP window and one argument beyond it; the
computed-argument and coalesced-call controls preserve exclusions outside
simple one-instruction forwarders.
`tail_call_stack_forward.tl` covers register permutations, duplicate stack
sources, zero/negative values and hidden aggregate-result pointers at opt0/1/2.
`tail-stack-forward-preserves-calls` pins its out-of-line fallback, tail jump
and aggregate-result forwarding at opt2 on both ABIs.

`backend-call-conventions` checks every IR call form, C and TypeLisp extern
aliases, variadic signatures, private by-value copies and call-fact lifetime.
`backend-call-convention-facts-parity` compares all convention-dependent ABI
facts on both targets, including invalid register indices and mixed-bank stack
boundaries. `backend-call-convention-emission-sites` turns on a `cfg test` hook
that gives Windows `Internal` calls RSI/RDI as fifth and sixth argument
registers, then checks where a TypeLisp call, C extern call, C function pointer
call, closure adapter forwarding to C or TypeLisp, backend runtime helper call,
TLS-arena intrinsic and variadic call place those arguments. Run these at
opt0/1/2; a convention-only refactor also needs exact before/after Linux and
Windows assembly for the integration corpus and compiler, plus the bootstrap
fixpoints.

`tc-module-index-job-owned` interleaves two job-owned declaration/import indexes
with colliding numeric names while a decoy interner remains installed. It keeps
an earlier job's payload readable through peer invalidation, shape rebuilds and
retirement, and covers wrapped imports, empty/offset views, payload growth and
owner-generation changes. The runnable typechecker smoke includes the same
probe; driver cleanup coverage verifies post-lowering release uses its supplied
job and preserves the other index.

`compiler-lower-function-env-scratch` lowers several functions against one
persistent module environment, including binding-store growth and a rejected
function. It checks parent bindings and cache metadata after each scratch
rewind, retirement of address-keyed memos, and readable escaped IR and errors.
Run the lowering suite at opt0/1/2; poisoned full self-compiles also exercise
post-rewind consumers across functions, closures and generated helpers.

`array_field_store_growth.tl` exercises field stores after dynamic-array
growth for register and memory-class elements, nested struct/tuple projections,
one-time index selection and mutable slices at opt0/1/2 on both hosts. Its
safety rows keep final bounds checks after the value's effects and reject
immutable receivers; intermediate projection traps remain independently pinned
by `set_intermediate_bounds_before_value_trap.tl`. The fixed-array and slice
`set_*_field_value_before_bounds_trap.tl` rows hold every array kind to the
same final check, and `compiler-lower-projected-store-checks` keeps a dynamic
element's field store at one check. `inline_array_field_store_growth.tl` covers
stores through an inline array field of a dynamic-array element after growth
(#9057), and `set_inline_array_bounds_before_value_trap.tl` the element check
that indexing its inline array needs before the value.

The `inline-checked-register-pool-isolation` optimizer smoke keeps inline
pricing identical before and after backend frame-pointer omission enables an
extra register, and checks that pricing restores its caller's pool. The IR
observability gate compares cold and repeated batch assembly for
`pure_call_join_live.tl`, including an empty predecessor, at opt0/1/2 for both
target ABIs. An invalid middle entry must retain its source diagnostic and
stop before later output is emitted.

`arena_branded_operands.tl` runs arithmetic, conditions, nested constructors,
aliases, stored holders and allocation scopes at opt0/1/2 on both hosts. The
public check/compile
cases also reject different arena brands and explicit bare annotations with
E0206 and a located diagnostic. `compiler-lower-typecheck-error-transport`
passes located and rich errors through both lowering diagnostic entry points,
checking the original primary span, code, help and secondary labels.
The checked let-binding fact tests cover declaration/body identity, ambiguous
names, frozen reads, generation reset and growth while a scratch arena is
active. Both retained maps must remain valid after that scratch is destroyed;
lowering must use semantic inference when a checked fact is unavailable.
The branded operand CLI cases also compare cold and repeated batch assembly.
They also compile `thread_safe_i64_vec.tl` for both targets at every opt level:
captured atomic owners must retain their semantic markers when a checked local
type carries that owner's allocation region. Conflicting checked proofs with
different regions must leave unrelated bindings available. The compile-profile
verifier pins trusted prelude hydration at zero declaration checks, checks
assembly parity with forced source, and rejects source/producer
mismatches. Semantic-index smoke tests with `--cfg test` assert that building
the index does not typecheck let initializers again.

`backend-colored-vector-id-extent` keeps nine wide values live across an
ordinary call and exercises allocation, stack coloring, final liveness and
emission on both SIMD widths and target ABIs. Its remapped homes extend beyond
the original variable count. Keep final side tables in that logical ID domain,
while existing compact-frame and register-home cases preserve the separate
physical slot count. The case also runs in the native SIMD backend suite.

`backend-empty-private-body-keeps-entry-stores-inside-frame` covers private
AVX2 parameter homes with and without debug info on both ABIs, plus distinct
instruction locations after coloring. `empty-private-params-debug-run` runs
the empty-body regression at opt1/2 alongside the non-debug controls.

`backend-debug-simd-caller-provenance` checks ordinary callers on both SIMD
widths and ABIs, with interleaved function locations, duplicate value keys and
bounds locations. The `debug-caller-*` cases in `tests/spmd/simd.cases` execute
the caller-home matrix witnesses at opt1/2 with their correct result or shift
trap, alongside scalar debug controls. The wide uniform-stack fixture retains
its existing AVX-512 private-argument diagnostic.
`backend-layout-keeps-debug-ends-after-cold-blocks` checks CFI, backtrace and
CodeView endings through cold-arm layout. `shuffle-lane1-debug-backtrace`
requires the trapped caller's `main` frame at opt1/2 on both SIMD widths.

`indirect_callee_never.tl` checks ordinary and tail indirect calls whose callee
returns early, for language closures and C code pointers. Counts require one
callee evaluation, no later argument effects and the enclosing cleanup. A
conditional callee also exercises the branch that actually invokes its function.

`extern_data_memory.tl` links C data symbols at opt0/1/2 on both hosts.
Its assembly-shape case pins both compare operand positions, arithmetic folds,
float and narrow reads against their exact extern metadata symbols. The
`backend-global-symbol-emission-owner` test reuses a backend owner with two
extern spellings and then no extern, resets function caches, and checks a second
owner's isolation and final retirement.

`indirect_callee_snapshot.tl` retains the callable before argument effects for
language closures and C pointers, including local, parameter, language and C
global and field storage, a capturing closure, raw pointer writes,
conditional/wrapped/factory callees and unchanged-callee controls.
Factory and invocation counts pin single evaluation. The native manifest runs
all three optimization levels on both hosts; keep the mixed-float, stack, null
and unsafe callable ABI families beside this ordering regression. The
`compiler-lower-operand-snapshot-shape` lowering test pins that ordinary and
tail callees are copied only when an argument writes their storage.

`addr_taken_frame_slots.tl` keeps scalar, narrow, parameter, loop-carried and
callable-copy storage private while a derived pointer remains live, at opt0/1/2
on both hosts. `regalloc-stack-only-address-slots` checks the same exclusion
through IR-text copies and joins. `addr_taken_frame_join.tl` covers the opt0/1
phi interaction; its independent opt2 load-forwarding defect remains #8514.

`tail_call_frame_provenance.tl` scrubs the callee's frame before reading a
reference or slice. It covers explicit and implicit field borrows, array and
tuple elements, local aliases, call-returned references, shadowed parameters,
heap aggregate copies and indirect calls at opt0/1/2 on both hosts. Its
assembly cases retain ordinary calls for unproven storage and for a borrowed
scalar local, whose copy is a frame slot (#9297), and tail jumps for reference
parameters, reborrows, caller-owned projections, heap storage and borrows of
dynamic-array and String locals, which lend their heap handles.
Parameter-derived slice rests keep tail jumps through nested patterns and a
300,000-element walk. Sibling local-array views and rebound rests retain calls,
checking that external-storage facts neither leak between arms nor survive a
reassignment.
The safety corpus rejects rebinding a reference parameter to a shorter local
borrow before forwarding it.

`with_arena_scalar_borrow.tl` is #9297's program: a reference to a scalar
local borrowed inside `with-arena` outlives the form, and the next allocation
reuses the rewound arena. `borrow_local_frame_storage.tl` extends it to
integer, float, bool, char and narrow locals, whole register-resident structs
and their fields, parameters, a match payload bound through a shared
reference, nested regions, a returned reference, a holder struct, borrow sites
in loops and `in-arena` followed by `arena.destroy-safe!`. Each case refills
the released arena before it reads, and `profile.alloc-total` must not move
around borrows of locals. Both run at opt0/1/2 on both hosts, and the
`borrow-local-no-alloc` assembly case forbids `tl_alloc` in the borrowing
function on both targets.

A lambda's by-value capture is storage of each call, so its frame-slot copy
is only sound because the ownership graph retires the capture at every return.
The `capture_borrow_*_reject` safety rows return or store a borrow of a
capture (scalar, register-resident field, a `String` snapshotted into a
`with-arena` region, under `with-arena`, `in-arena` with
`arena.destroy-safe!`, auto-borrowed into a lifetime-carrying call, nested
lambdas, a captured lambda parameter); main accepted each, and each must
report the capture's E0205. Two controls keep the inferred-result and
lambda-parameter diagnostics. `capture_borrow_storage.tl` runs the accepted
side at opt0/1/2 on both hosts: captured references returned or reborrowed,
non-escaping borrows (lent, annotated with the capture's lifetime, in a loop),
shadowing, nested lambdas and field borrows. Its lambdas differ in signature
or body, because opt2 still fails to link two identical capturing lambdas
(#9317).

`tail_borrowed_enum_match.tl` keeps borrowed array-element and field walkers
in one frame, including register-resident enum spills. Their tail jumps and
opt2 loops are checked on both targets. The frame-provenance corpus also
checks borrowed enum arms with scalar/tuple fields, Copy-array slices,
call-returned references, nested matches, reassignment and shadowing.

The broader work is tracked by the parity umbrella
[#641](https://github.com/JoNil-Botta/typelisp/issues/641), the selfhost CI
suite gate [#520](https://github.com/JoNil-Botta/typelisp/issues/520), and the
bootstrap/fixpoint gate [#47](https://github.com/JoNil-Botta/typelisp/issues/47).

`compiler-driver-retained-image-owner` in `compiler_driver_smoke_tests.tl`
checks embedded-image retention, nonpositive and nested owners, forgetting a
borrowed owner, and reuse after the previous owner is destroyed. Run it at
opt0, opt1 and opt2. The native-route stress and stdlib identity differential
gates retain their complete native/source batches, mapping lifecycles,
source-mutation fallbacks and failing-entry diagnostics.

The gate table, the gate/tool classification and the canonical script entry
points are documented in [`../scripts/README.md`](../scripts/README.md); the
user-facing `typelisp test`/`doc --test` behaviour, the stage0 workflow and the
seed policy are in
[`../docs/testing-and-bootstrap.md`](../docs/testing-and-bootstrap.md).

`tests/spmd/float_comparisons.tl` uses integer ranks for all six f32/f64
predicates over signed zeros, finite values, infinities and quiet/signaling
NaNs in either operand. The SIMD cases run scalar/AVX2/AVX-512 at opt0/1/2
over empty, singleton, full-gang and tail lengths, check inactive sentinels,
and compare selected payload bits. Shape rows retain ordered packed GT/GE
on both target ABIs; backend IR-text cases cover register and spill operands
and unchanged AVX-512 signed/unsigned integer predicates.

`backend-spmd-entry-preserves-every-unread-input` checks every incoming operand
against earlier writes to its physical XMM/YMM/ZMM aliases on SysV and Win64.
Mixed f32/f64 uniforms have register and frame homes alongside integer,
varying and bool inputs; the AVX-512 mask swap retains its parallel schedule.
Keep the stack-float entry-copy regressions beside it. The required SPMD
`private-helper-entry-uniform-float-run` case runs the out-of-line reproducer
in scalar/AVX2/AVX-512 at opt0/1/2, including a partial gang and every lane's
result. Missing execution routes remain unverified.

`spmd_uniform_index_write.tl` preserves unmasked uniform receiver/index/value
writes across empty and tail domains in scalar, AVX2 and AVX-512 modes. The
paired safety cases reject a uniform destination when the value is varying,
including local-class merges, conditionals, bool slices and rank-2 domains.
Masked branches retain their canonical-index requirement even for uniform
values; serialized `foreach-active` keeps its existing collision semantics.
The positive fixture also pins ordered scan writes, including through a
helper and into an array element's field, and skipped empty-range bounds
checks. Compaction, a `foreach` following a scan and a `foreach` inside a
helper called from a scan reject colliding varying stores, so the ordered scan
context cannot authorize parallel writes. Field and tuple-element places
through a uniform array index, and fields of a struct declared outside the
`foreach`, reject varying values. `spmd_private_storage_write.tl` keeps
varying writes into body-local and helper-local arrays and structs accepted;
the paired private-store rejects show that values read back from that storage
stay varying.

The aggregate-global backend escape fixture rejects the safe-reference shape
with E0222 and checks its raw-pointer counterpart against the inline-home
assertions (SPEC 4.x: an initialized aggregate global is one storage home whose
assignment keeps that home). The indirect-call shape remains independently
covered.

`package-embedded-math-initializers` and `package-source-prefix-macro` check
source global macro initializers before dependency imports at opt0/1/2 on both
hosts, with cold/cached dependencies and explicit disk-root comparisons.
`package-source-prefix-return-type` rejects an invalid entry-owned function
before the import on all three routes. Existing package native/surface gates
retain their exact trusted-prefix, native/source parity and rollback assertions.

`package-dependency-aggregate-abi` in `tests/cli/public-package.cases` builds and
runs separate dependency and consumer objects at opt0/1/2 on both hosts. It
covers 8/16/24-byte integer structures, signed boundaries, floating and mixed
register classes, stack pressure, hidden result pointers, references and
borrowed strings. Saved values cross another call before use, including a
tuple whose physical group appears only in the dependency signature. The
lowering and IR smoke tests keep layout-only group facts, malformed transport
types and conflicting group observations covered. The package runtime lifetime
test compares ordinary and Windows package assembly at all three levels for
constructor-free nominal groups with all four integer/SSE word masks. It runs
on either host and checks the retained output after scope cleanup. Native Slice
extern rejection remains in the safety corpus. The backend admission fixture
exercises missing indices and entries, conflicting widths and register classes,
and valid one-word/all four two-word layouts in parameter and result positions.
Both assembly and object emitters on both targets must reject unresolved
TypeLisp extern layouts while retaining native C extern behavior. Rebuilding the
index must preserve missing facts even when native or pointer declarations of
the same nominal type appear first.

`gep_global_capture.tl` retains a raw pointer's selected global base and offset
across rebinding and checks the old pointee alongside the new global value at
opt0/1/2 on both hosts. The `gep-split-mutable-global-capture` optimizer test
covers implicit `Global` and `RuntimeGlobal` reads in both GEP operands across
stores and calls, with stable literal, address and SSA splitting controls.

`global_aggregate_storage_lifetime.tl` checks that an inline aggregate global
keeps its static home (SPEC 5.10) after scratch and explicit arena destruction,
nested scopes, repeated writes, large arrays, MoveOnly Box payloads, and
local/global receivers captured across conditional, transitive and recursive
whole-global replacement: a store into a captured element of the global lands
in its home. It also checks that the caller's arena is restored and that these
stores allocate nothing. `global_aggregate_storage_threads.tl` races first use
from two workers writing distinct globals and reads the results only after
join. `global_aggregate_storage_boundary.tl` repeats 258 replacements in
temporary arenas while an element place into the home is captured, and checks
that every store lands and none allocates. All three fixtures run at opt0/1/2
on both hosts. The existing `scratch_body_global_store_reject.tl` keeps source
allocation escape illegal. The arena-debug gate repeats all three fixtures with
debug, profile, and backtrace instrumentation together, using a test-enabled
emitter, checking that each runtime feature is present and that no store
reaches the private global allocator. The shared-object backend test pins both TLS
switches and their scratch register, which must preserve the allocation result.

The parser origin-column tests exercise all thirteen kinds, compact-span
boundaries and exact overflow after i64-to-i32 conversion, full-width name IDs
and alias keys/slots, segment and directory growth, retained handles, suffix
rollback, detached directory transfer, alias precedence and the 64-step depth
bound. They also check independent jobs, failed/inactive nested modules and
ordinary reader builder growth/reset. The load and semantic-index smokes cover
cached file reuse and source-arena retirement on the production paths.

## Loader diagnostic codes

The `loader-error-codes` public CLI case checks source-facing loader failures
through check/compile on both targets, including cross-file parse forwarding,
explicit module identity overrides, and a local collision's secondary label.
`compiler_load_tests.tl` checks explicit loader-API identity mismatches and
code/category parity between ordinary and package walkers, legal import cycles,
pending generators and missing text/binary includes. Registry and explain
tests require every published loader code to remain documented.
`loader-package-include-resolution` checks E0303 and the include's source span
for an unknown package alias on both targets. `loader-unpublished-identity-code`
keeps E0306 out of the public registry and explanations; explicit API identity
constraints remain tested as E0303 resolution errors.
The package/plain parity cases exercise sibling, nested, separate-parent and
self-repeated module bodies through check/build on both targets, plus missing
local modules with and without dependencies. Distinct bodies and inactive cfg declarations
remain accepted; explicit unknown `pkg:` include aliases remain E0303.

## Packed field receivers

`packed_field_receiver.tl` runs at opt0/1/2 on both hosts. It checks one-word
and two-word sibling writes, mutable-reference calls and whole-referent writes,
conditional and equal-content rebinding, nested stores, loops, shadowing,
zero-sized fields, and tuple/memory-class controls. A rebind in the value
copies into the receiver's home, so the store lands in the variable (SPEC 5.10).
A scalar transition oracle checks both packed widths across 99 input/action
combinations. The lowerer test pins the absence of runtime guards and heap
allocation. `set_place_eval_order.tl` covers the same rule for element, element
field and tuple-element field places. The paired safety fixtures retain rejection of live borrowed roots
and immutable field access.
The existing `raw_pointer_register_addr_of.tl` and `struct_field_set.tl`
fixtures also run at opt0/1/2: they cover an address exposed before the RHS,
sub-word integer and floating fields, and move-only boxed field values.

## Store and constructor exits

`store_operand_exits.tl` and `store_constructor_exits.tl` run at opt0/1/2 on
both hosts. They cover scalar, aggregate, field, tuple, box, reference, raw
pointer, global and array stores; return, break and continue; skipped bounds
checks and later constructor arguments; zero-sized values; and conditional
fallthrough. `compiler-lower-store-exits` inspects unoptimized blocks for any
instruction after a terminator, including annotation, replacement, constructor,
direct/indirect call, C ABI and syscall paths. The paired safety cases retain
canonical rejection of immutable receivers, wrong return types and invalid
unreachable tails.

`literal_constructor_exits.tl` runs at opt0/1/2 on both hosts. It checks Box and
tuple return/break/continue, nested and zero-sized elements, skipped later
effects and conditional fallthrough. `compiler-lower-literal-constructor-exits`
also rejects unoptimized instructions after a terminator. The paired safety
fixtures keep invalid returns and unreachable tuple elements type-checked.

`exit_operand_consumers.tl` runs at opt0/1/2 on both hosts. Exiting
constructors, annotations and scalar operands feed let and `with` bindings,
match scrutinees, field/tuple/array projections, `deref`, casts, unary and
binary operators, `if` conditions and owned `for` sources in tail and value
position, and inside loops whose opt2 form must keep no code after a
`continue`. It also checks evaluation order and exactly-once cleanup.
`compiler-lower-operand-consumer-exits` rejects unoptimized instructions after
a terminator for the same consumers; `let_exit_unreachable_type_reject.tl`
and `cast_exit_unsupported_reject.tl` keep bindings and conversions after an
exit type-checked.

## Runtime byte search

`tests/integration/runtime_memchr.tl` compares the runtime byte search with a
byte-loop oracle at every SIMD alignment, lengths 0 through 65, every hit
position and all byte values. It checks adjacent matches, misses, non-positive
lengths with a null pointer, public string offsets, and Linux inaccessible
pages before and after the range. The native manifest runs it at opt0/1/2 on
both hosts; its inline test runs the same checks. The focused runtime leaf test
also compares the complete Linux/Windows search bodies after ABI substitution.

## Reference and place reads

`clone_reference_referent.tl` checks non-Copy struct, enum and array clones
through shared/mutable references, projected and compound results, macro
expansion, receiver evaluation count, independent storage and Box cleanup at
opt0/1/2 on both targets. The paired `clone_reference_*_reject.tl` safety cases
preserve ordinary prefix/initializer moves, source use-after-move, callable
shadowing and the unsupported direct-reference clone boundary. Keep these
alongside the existing move-out-of-reference and clone capability controls.

Reference-place regressions (#8696) extend the typechecker move-test table with
valid mutable dereference replacements, reborrows and nested Copy box reads,
plus exact shared-mutation, aliasing and move rejections. The
`reference_place_read` native matrix checks transferred old values, retained
storage, index evaluation and replacement order at opt0/1/2; the
`replace_place_*_reject` safety rows preserve the consuming boundaries.
`compiler-typecheck-place-through-shared-ok?` and the
`replace_place_through_*` and `reborrow_through_inner_shared_array` rows
reject a `replace!` place or `&mut` reborrow that reaches a `&mut` through a
shared reference: directly, in a tuple, array, struct field or Box payload, as
a Copy field, through two copies of one shared reference, and with a shared
reference between two mutable ones. Each must report the `&mut` borrow
diagnostic (E0207), not an incidental move error.

`replace!` takes the place's own old value (#8889): the move-test tables check
box contents reached through `&mut` (directly, through a field, nested) as
returned owned values, the referent of a computed reference held in a
temporary, and the writability of every reference on the place's path, which
rejects a `&mut` reached through `&` with E0207 "mutable borrow through a
shared reference" for each container shape and for `set!` (main's
`replace_place_through_*` rows, the `replace_through_shared_*` and
`set_*through_shared_mut_reject` safety rows). The `replace_place_paths`
native matrix runs the accepted shapes at opt0/1/2.

A view's writability follows the references it was read through: the
`view_mut_*_ok` safety rows pin main's exit values for writes, `replace!`, a
mutable loan and a view of a view through `&mut`, the `view_*_reject` rows keep
the owner and other views unusable while a mutable view is written and every
write through a `&` path rejected, and the `view_mut_write` native matrix runs
each write form, a copied view and a loop at opt0/1/2. The move-test table
`compiler-typecheck-view-writability-ok?` checks both sides. A binding of a
match on a view keeps the view's writability: the `view_match_binder_*_ok`
rows pin main's exit values for a field store, box contents, `replace!`, a
mutable loan, a match on a view binder and a loop; the `view_match_binder_*`
rejects keep the owner, another view of the path and a second match's binding
unusable while a binding is written, and reject every write through a `&`
path; the `view_match_binder_write` native matrix runs each form, an
or-pattern, two payloads and a binding of a binding at opt0/1/2, and
`compiler-typecheck-view-match-binder-ok?` checks both sides.

A `(&mut program T)` is Rust's `&'static mut`: `program_mut_holder_uses_ok`
(main's typecheck-smoke holder among them) reads, writes, passes, stores,
moves and matches holders of one; the `program_mut_*_reject` rows reject a
`&mut` reborrowed into a `program` region and used again (main accepts the
aliasing), a reborrow through a holder returned as `program`, a store through
a payload bound through `&`, and a borrow of a local passed for a `program`
parameter (`program_param_*`; `program_param_shadow_ok` keeps a parameter named
`program` an ordinary borrow); `compiler-typecheck-program-mut-holder-ok?`
checks both sides.

## Linux thread storage

`tests/integration/thread_local_word.tl` checks the private Linux runtime word
at opt levels 0, 1 and 2: initial zero, simultaneous thread isolation, fresh
storage after repeated spawn/join, and address/value stability across arena
switching, reset and destruction. The `thread-local-word-*` rows of
`tests/codegen/integration-fixtures.cases` repeat it with allocation profiling
and backtraces. `verify-compiler-arena-debug.sh` uses its test-enabled emitter
for the debug and combined layouts, asserting that debug/profile/backtrace
storage and renderer symbols really exist before running each binary. Its unsafe
declaration is paired with `thread_local_word_unsafe_call_reject.tl` in the
safety corpus. This accessor is a freestanding Linux ABI primitive.

## Generated cfg declarations

`macro-unqualified-import-cache-clears-live-key-storage` poisons all 65,536
cache slots in a virgin owner arena. It checks full-array clearing for explicit
invalidation and stale table/generation IDs, retention for a valid generation,
unchanged name/value payloads and isolation from another live job.

`source_selected_generated_export.tl` exercises selected aliases of generated
macros, nested generators and a non-entry importer, with a caller-local shadow
to check caller-syntax hygiene and an earlier qualified provider whose macro
shares the selected alias's spelling. Its native row and the public package build
case run at opt0/1/2 on both hosts; the inline test reaches the same assertions.
The paired safety cases retain located missing-selection and alias-collision
errors after provider expansion.

`tests/integration/generated_cfg.tl` constructs conditional syntax in both
`Decls` and `Module` macros, including nested expansion and inactive missing
imports. The native integration manifest runs it at the default level and pins
opt 0, 1 and 2 (`generated_cfg_opt{0,1,2}`). Also run it with
`--cfg generated-cfg-feature` to exercise the opposite custom branch.
The consolidated codegen suite's `driver-generated-cfg` child alternates custom
flags and Linux/Windows targets across two reusable driver states, checks that
B leaves A's intern/pool counts intact, and reuses A after changing its flags.
Keep that test on the canonical driver path; a cfg string in a cache key alone
does not supply predicates to macro expansion. The semantic-index macro checks
also alternate the same source's cfg set and verify complete results and owner
release. The fixture's inline test covers harness expansion, and the existing
public CLI package build/run smoke emits target-conditional Module declarations
through the package preparation and object/assembly paths.
The paired `generated_cfg_missing_decls_import_reject.tl` and
`generated_cfg_missing_module_import_reject.tl` safety fixtures require enabled,
unused generated imports to reach the resolver for both result kinds.

## Global call borrow effects

The original `inline_aggregate_global_live_borrow_reject.tl` escape shape
is rejected by the public check/compile corpus on Linux and Windows targets
at opt0, opt1 and opt2. Its valid borrow-ending counterpart remains in the
native integration matrix and has the same result at every level.

`compiler_global_effects_tests.tl` covers recursive witnesses, nonwriting SCCs,
indirect unions and positive/negative cache invalidation. The graph-append
retirement and explicit-job isolation tests live in
`src/tests/compiler_typecheck_core_tests.tl`. The `global_call_*` safety rows exercise
whole/projected/buffer writes, address-taking, mutable loans, transitive and
recursive calls, indirect functions and closures, macro and imported setters,
explicit and synthesized cleanup, and the allowed Copy/different-global/ended
borrow/explicit-parameter cases. Keep their named call-chain diagnostics when
changing traversal or binding resolution. Enum-pattern rows keep global writes
visible through bare variants with known parameter types and unknown nested
scrutinees; the constructor row keeps local binders and compiler primitives
pure. Loop-scope tests preserve body binder values across nested bound scopes.
Match-shadowing rows distinguish a
loan created from the global before a same-named pattern binder from a loan
created from a shadowing local, including loop arms. The typecheck self-test
checks captured global identity through both union orders, snapshot restoration,
cloning and dense-store growth, and requires fixpoint equality to distinguish it.
Later-argument let/for shadowing must preserve an earlier global loan, while
mutating a separate same-named local remains valid. Root removal, owner selection
and exact loan removal are checked with both owners present in one snapshot.
The global-prefix metadata test grows a dense store through several capacities,
retains a local-only earlier snapshot, and filters a global back out; every
prefix must report exactly the global handles reachable in its parent chain.
The same owner identity selects lending-use propagation and prevents a local
fact from suppressing a global loan during return, loop, or stored-loan protection.
The public shadowing matrix requires the secondary diagnostic to point to the
original global borrow when a later local borrow has the same spelling.
The mixed-argument rows distinguish an independent local loan plus a by-value
global copy from a global auto-borrow; the copy runs at opt0, opt1 and opt2.
The temporary-cleanup rows cover later arguments, returned references, forward and indirect callees, ended
borrows, and loans ending at the call before cleanup.
`tests/inline/compiler_global_call_cache.tl` checks a reused source prefix
against a changed callable union, reinfers temporary disposers after file
reset, and preserves cache hits for context-independent prefixes with module markers.
Qualified-name rows reject full dotted callees and global roots while permitting
a pure qualified helper even when a global-writing callback exists. Public CLI
and LSP fixtures assert E0222, the primary call and secondary borrow locations, and `explain` text.

## Persistent lifetime memo

The `lifetime-outlives-memo-*` inline tests in
`src/tests/compiler_typecheck_core_tests.tl` cover lexical ordering and shadowing,
more distinct lifetime pairs than memo slots, local environment cache layers,
invalid/missing lifetimes, interleaved jobs, allocation under a retired decoy
arena, job reset/destruction, reused function scratch, and explicit structural
session reset while the installed interner stays unchanged. Run them at opt0,
opt1 and opt2. The normal safety and integration corpora keep reference coercion
and arena-escape diagnostics covered through the compiler entry points.

## Intern ID provenance

The ID provenance contract is stated at the top of
[`compiler_intern.tl`](compiler_intern.tl). Parser tokens enter the source
interner once through `intern-source-slice` and AST name fields keep that ID;
compiler-created names use the `intern-generated-*` APIs; builtin, hygiene,
dotted and module-qualified names are created or mapped by their owning ID API
rather than by interning a rendered String in a later phase. Name IDs in
`AstDecl`, `AstExpr`, patterns, parameters, fields, and nominal `AstType` nodes
all belong to one `InternCompatState` table. AST fallback payloads, negative
sentinels, and structural composite keys are not intern IDs; use the owning
subsystem's renderer rather than `intern-str` for those values. Lifetime/region
names, diagnostics, import metadata, and compatibility records may legitimately
remain `String` values.

An ID is valid only while its owning table and generation are installed.
Within an installed state, insertion order makes IDs deterministic. Installing
another driver state changes the owner even when its generation counter and
numeric IDs happen to match, so the same numeric ID may mean different text in
two driver states. `intern-reset!` invalidates every retained ID;
`intern-reset-to!` preserves only source IDs below the mark but still advances
the generation. State-owned reset/capture/install operations affect only that
driver job.

Synthetic compiler fixtures initialize builtin IDs before constructing checker
environments or reading fixed IDs; the IR-text reader supplies that boundary
for IR fixtures. Later-phase accessors keep their owner/generation guard.
Destructive intern fixtures use `compiler_ast_types_tests.with-test-interns`,
which installs a fresh table with its builtin state and restores the caller's
matching pair before releasing fixture storage. A captured intern view shares
arrays and cannot undo a reset of the caller's table. After a reset inside a
fixture, initialize its new builtin generation before using it. Fixture bodies
must complete normally, without an early `return` out of the scope.
`tc-type-env-intern-builtin-fixture-state` pins nested owners, reset generations,
synthetic cache setup and caller restoration. Run the entire compiler-core file
in declaration order and with shuffle seeds 1 and 17 at opt0/1/2, plus the
optimizer file's filtered aggregate cases and full shuffled suite.

`intern-str` is the short-lived, same-state compatibility path. Code that
retains an ID across a reset or install boundary resolves it through a captured
`InternSourceNameSession`, whose `InternSourceNameResolution` rejects
wrong-owner, stale-generation and invalid identities explicitly. Do not cache
String data pointer/length pairs as name identity across scratch/region reset:
address equality is only a fast path while both live operands are in scope.
Interning must own/canonicalize any spelling that survives its source arena.

Instruction source-span keys classify their function component as a one-word
`CompilerIrSymbolId`. Their destination variable, stored-name, and bounds-label
components remain function-local `i64` indexes. Producers and consumers that
still carry a function's name as a raw `i64` must wrap it at the source-span
API boundary; a raw integer must not enter that key as the function identity.

`compiler_intern_tests.tl` owns source-name reset cases, the registered
`compiler-typecheck-structural-intern-session-isolation` test owns explicit
structural-session isolation/reset/growth, and `compiler-backend-self-test`
covers equal numeric IDs with different spellings. `compiler_ast_types_smoke.tl`
owns synthetic AST construction, empty-name compatibility, and pool reset
cases; `compiler_parse_smoke.tl` owns parsed-token identity.

`tests/compiler_module_name_tests.tl` pins the shared complete dotted-import
grammar across parser symbols and LSP names, including byte-level Unicode,
punctuation, path rejection, long names, diagnostics, and import metadata.
Source-token fixtures also compare parser and LSP acceptance. Separate editor
prefix cases and unsupported-byte fixtures ensure incomplete or invalid operands
cannot resolve a valid prefix. The existing parser and LSP smokes retain alias,
wildcard, string-path diagnostics, and editor integration coverage.

## Optimizer dense block scans

Whole-program optimizer fixtures use `with-test-inline-mode` around the
production entry. That entry arms the checked inliner, while direct band tests
deliberately start disarmed and checked-tier tests may start armed. Restoring
the caller's mode prevents declaration-order dependencies without changing
production behavior. The owning inline regression covers both initial modes;
run the optimizer smoke in declaration order and shuffle seeds 1 and 17 at
opt0/1/2 when changing this boundary.

The `call-memory-dense-scan` inline test in `compiler_optimize_tests.tl`
compares linked, dense and mixed blocks across growth, empty inputs and
retained rescans. It checks the two forward root passes, single-source
rejection, summary accumulation and call/write classification. Spare slots
contain observable poison; a later write must not change an already true
predicate or unresolved candidate. Visit-counter mutation probes verify the
cutoff without relying on invalid IR. Keep these storage checks alongside the
existing call-memory semantic fixtures when changing traversal or block
representation.

`inline-literal-dense-scan` in the same module compares the inliner's complete
definition/literal counters across linked, dense, and mixed block storage, with
independent expected results. It covers empty sequences, builder growth,
duplicate and nonliteral definitions, missing and boundary IDs, traversal
order, and rescanning retained input. Keep both the counter and admission
coverage when changing this scanner.

`string-literal-length-fold` checks empty and UTF-8 byte lengths, direct and
variable literal bases, both length-slot GEP spellings, parameter/duplicate
definitions, address-taken bases and destinations, and unsupported offsets and
load types. `tests/integration/string_literal_eq.tl` checks every comparison
width and runtime equal/different values at opt0/1/2 on both hosts; the matching
assembly case pins the specialized four-byte comparison and its immediate
little-endian literal word.

`string-literal-data-fold` checks all integer widths and signedness through
literal descriptor/data loads, copied pointers, word-preserving casts and
cross-block definitions. It keeps unknown runtime descriptors, aliases with
real pointer writes, nonunique definitions, unsupported casts/types, negative
or overflowing offsets and overreads as loads. Descriptor words, non-zero
descriptor slots, second pointer loads, narrow pointer loads and moves, phi
pointers and non-integer element strides also stay loads; removing the
data-mode, descriptor-slot, stride, pointer-load or word-type guard fails one
of these controls. Its deep-chain boundary and cyclic definitions check that
proof walks terminate conservatively. String
operands alone use constructed IR because their text spelling is not lossless;
the instructions and expected replacements use parsed IR text. Keep these
checks with the existing literal-length and native equality coverage.

The `copy-call-byte-copy` test also verifies copy/fill exit-value suffixes:
the counter step must follow the memory operation, and only copies and the
loop comparison may follow that step. Its authored IR shares `i + 1` directly
between addresses and the step, retains later address/arithmetic/load uses,
and keeps a valid post-store step with a copied exit value as a positive.
`tests/integration/copy_call_shifted_step.tl` checks shifted byte and word
copies at zero, one, four and nine trips at opt0/1/2, including unchanged
sentinels and the returned counter. Spare initialized storage keeps the
historical wrong-offset copy in bounds, making a value mismatch the witness.
The same self-test verifies actual positive-bound entry facts for copy and
fill loops: selected signed comparisons, a true conjunction and a forwarding
preheader admit the helper; fabricated guard names, bypass paths, wrong edges,
unsigned or mismatched counter types and proof-budget exhaustion retain the
original loop. Each authored input is verified before transformation.

## Move joins and diverging arms

The `fixed-array-reference-value-and-place-access` virtual-source matrix rejects
non-Copy transfers through shared and mutable array and Slice references,
including `slice-view` results, across bindings, arguments, results, branches,
containers and stores, including matching signature lifetimes and
reference-valued receivers. A `string-data` operand is a place read whose
control-flow inputs keep their transfers. Copy aggregates and fields,
borrowed elements, deep clones and observing primitives stay accepted. Clone
result flows through control structures keep condition, initializer, scrutinee,
prefix and index transfers checked; ordinary projection receivers keep value
semantics for their control-flow inputs. Reborrow and replacement controls
distinguish reading a place from transferring its element. The public
`fixed-array-reference-*` cases pin E0208 and source locations through check and
compile for both targets at every optimization level. `array_reference_reads.tl`
runs the corresponding positive paths, Slice borrows, clones and replacement,
and owned moves in the native matrix. The `array_shared_element_move_reject` and
`slice_shared_element_move_reject` safety rows return a borrowed element under
the reference's own lifetime.

The public-check `check-invalidated-parameter-*` cases retain read locations,
invalidation secondary labels, ownership help and decoded E0208 diagnostics
for multi-expression functions, lambdas and nested lets. Both direct safe
destroy and imported invalidation helpers run through `check` and `compile`
on both targets; compile covers opt0/1/2. Read-before-destroy cases must pass.
`tc-copy-projection-source-views-reuse-checked-receiver-facts` also keeps the
checked receiver lookup through source and macro views, with non-Copy and
unknown fields retaining their consuming dereference.
`check-invalidated-parameter-field-read-span` locates dotted field reads
(`pair.count`, `pair.text`) at the read in multi-expression, `begin` and
single-expression bodies; `compiler-check-invalidated-field-read-spans-ok?`
pins the same primaries and origin labels through the virtual-source checker,
and `tc-move-located-view-names-the-enclosing-read` the view itself.
`check-foreign-global-write-locations` keeps #7976 writes at the `set!` target,
and an owner macro's write at its invocation in the importer's file;
`check-with-owner-invalidation-location` keeps E0212 at the arena or phase
argument.

`match_copy_loan_ends_ok` overwrites freshly borrowed enum, tuple, array and
projected storage after pattern binding, including dynamic indexes, or-patterns,
branches, nested shadowing, loops and an unused reference payload. Its native
rows run at opt0/1/2 and assert the original Copy values. Keep the existing
`borrowed_pattern_copy_deferred_ok` matrix: calls and stores must force eager
payload snapshots when lowering cannot prove that every read precedes a write.
The paired `match_copy_*_loan_reject` and `match_reference_result_loan_reject`
cases retain earlier argument loans, loop-carried references, scrutinee stores
and reference-valued arm results. The scrutinee-store case must still reject
when the arm itself never reads the stored reference. The shadowed-owner and
shadowed-result cases use exhaustive single-arm matches, so another arm cannot
accidentally preserve the loan that a shadowing pattern binding would erase.

`tests/safety/move_diverging_*` and `move_*_reject` run the programs that an
early `return`, `break`, `continue` or `never` call used to poison, next to the
rejections that must survive: a move in an arm that completes normally, in both
a diverging and a normal arm, inside the diverging arm itself, and before the
branch. Two rows pin what is *not* divergence: an arm containing `try`, which
may propagate but may also continue, and an arm whose only `return` belongs to
a lambda defined in it. `move_diverging_reinit_other_arm_ok` keeps an arm that changes nothing
but diverges opposite an arm that reinitializes; skipping unchanged arms
unconditionally breaks it.

The `with_owner_*_reject` rows are the soundness half. Lowering cleans an active
owner on every normal exit edge, so the move checker validates the owner at
each `return`, recoverable `try`, `break`, `continue`, and fallthrough before
dropping diverging arms from joins. Keep whole-owner, `(:owned)` field, `match`
and loop `break` forms when changing either join. The `let_obligation_*` rows
also require explicit discharge on every normal exit. Their value-tail cases
check that transparent scopes and branches return the same visible owner,
that shadowing cannot discharge an outer binding, and that `never` tails need
no cleanup. The scope-owner state test installs an unrelated intern pool while
keeping a lexical snapshot and verifies that its owners and loop depth survive.
The deep-loop fixture distinguishes depths 63 and 64 while running both cleanups.
The join fast path runs for every branch in a self-compile; measure typecheck-only
instruction counts on identical source when touching it.

## Discarded speculative errors

Macro operand capture type-probes each operand and keeps only a successful
type; the errors of failed probes are dropped. `tc-expr-discarding-errors`
opens a job-owned suppression scope so such an error is not finalized with a
near-miss scan over every visible name. The
`tc-unbound-suggestion-suppression-scope` inline test in
`src/tests/compiler_typecheck_core_tests.tl` checks nesting, that only the
owning job is silenced, and that the suggestion returns after the scope;
`tc-expr-discarding-errors-balances-its-scope` checks both outcomes close
the scope. `macro_operand_unbound_suggestion_reject` is the user-visible half: a
name that fails the probe and then fails for real must still report "did you
mean". Only a caller that drops the error unconditionally may use the wrapper;
wrapping a path whose diagnostic can reach the user silently removes suggestions
and only that safety row would notice.

The opposite mistake, a new speculative caller that forgets the wrapper, is
caught by `scripts/verify-compile-profile.sh`: it checks a small program whose
stdlib format macros discard probe errors while compiling cleanly, and
requires `typecheck.env.unbound_finalizers` to be positive (the fixture reaches
the path) and every `typecheck.env.unbound_scans` row to be zero.

`tc-check-defmacro` also evaluates a context-free macro body once at its
definition, on placeholder operands: a `Var` per ordinary operand and an empty
list per variadic. Only a completed run's produced type is checked there. A
failed run is not an error, because the placeholder path can be exactly the
`comptime-error` arm or out-of-range inspector call that no real call takes. The
typecheck self-test's `defmacro-probe-error` rows and
`macro_untaken_comptime_error` native row put such arms before and after the
taken arm for expression and `Decls` macros, and require a taken arm to still
report the author's message. The package fixture's `package-first` pair repeats
the operand-count guard and puts rejecting arms before and after the selected
arms on the dependency route, which `verify-package-native-tlci.sh` runs
natively and through forced-source CTFE.

## Logical SPMD gang geometry

`compiler_spmd_logical_gang_tests.tl` covers every admitted numeric lane,
backend and logical width with ordered coverage and lane-by-lane mask oracles.
It checks empty/full sets, every singleton and prefix boundary, alternating
patterns and non-prefix edges, including bit 63 and unoccupied physical lanes.
Coordinate/conversion cases pin eight i64 pieces and narrowing into a partial
physical vector. Malformed descriptors and extreme signed integers exercise
validation before division, multiplication or shifts; diagnostics are exact.
The closed backend enum excludes unsupported modes at type checking.
Run the companion at opt0/1/2 with a freshly built compiler and both stdlib/src
roots. `compiler-lower-native-lane-table` checks all nine lowerer modes against
the previous numeric width table, including non-numeric rejection. The existing
SPMD differential and shape gates retain end-to-end lowering coverage.

## Stack traffic evidence

`compiler_stack_traffic_tests.tl` checks the #9242 typed boundary for #7236:
all closed owner/bank/access/region kinds, unique emitted-operation keys,
source identities across inlining, ordinary traps without fabricated sites,
region-parent consistency, logical homes, malformed graph
indices/reverse edges, nested regions, disconnected and acyclic control flow,
self loops and an independent transitive-closure oracle over all 64 three-node
graphs without self edges. The oracle separately checks ordered same-home
write/read paths with no intervening header visit, both static event orders
and `ReadWrite` events. Keep mutually exclusive arms, different homes,
setup/exit-only traffic and read-before-write negatives; same-block access
ordering, child-control paths, inner-cycle revisits and entry reachability
remain explicit fixtures. SCC access counts are not ordered witnesses. Keep
the v1 JSON golden, escaping and exact/spare IR capacity checks. The native
smoke runs the same checks at opt0/1/2 on both hosts.
The producer/report integration remains #7236; these fixtures do not certify
actual backend ownership or publish a warning.

## SPMD decision provenance

The `compiler-lower-spmd-decisions-*` inline tests inspect final typed source
facts, including native and scalar routes, explicit scalar operations, rejected
maps, empty/tail ranges, cross-lane parent identities and deterministic order.
Control-flow cases retain inactive source sites after returns and earlier
errors without hiding later live or rejected sites. Empty scalar loop bodies
that lowering emits keep their decisions, including nested rejections. Terminal completion is
separate from provisional plan selection. Lambda cases pin distinct typed
function identities with independent source ordinals. Repeated captured syntax
has separate sites for each expanded occurrence, including nested empty regions
and native cross-lane operations revisited by scalar-tail lowering.
Macro cases distinguish primary generated spans from actionable invocation or
argument spans, keep frame context local to the generated subtree, and enforce
the frame bound. Preserve those checks when changing macro transparency or
expected-type/tail lowering: either boundary can lose a source-node link even
while emitted programs remain correct. The IR source-span escape smoke checks
owned records after destroying the producing arena. Optimizer and backend
span rewrites must preserve source IDs independently of instruction remapping.
Fully unspanned API fixtures cover all six forms and nested source sites; payload
copies must not lose identity or turn visited children into inactive records.

## Vector reduction source ownership

The backend self-test checks AVX2 i64 min/max with register and spilled
sources. It checks the scalar destination and forbids writes to the source's
XMM/YMM family; the reduction result alone cannot detect a write through the
source alias (#7821). Call-adjacent spill fixtures require independent reloads
without overwriting the retained stack source. Preserve both the
source-ownership and signed-comparison checks when changing horizontal
reduction emission.

## Borrowed macro surface searches

The typecheck smoke suite's surface-macro provider covers first/last/missing
names, a non-macro function with a larger signature, and distinct intern IDs.
It retains a selected macro signature across destruction of the loader's
summary arena, then checks its parameter and return type. Read-only candidates
must use borrowed declarations; selected signatures must own their payloads.
The complete inline batch and `windows_param_preassign_backend.tl` exercise the
compiler-sized search workload that exposed copying during failed lookups.

## Captured syntax-list builders

`compiler-ctfe-captured-list-builders` checks `expr-list-cons` and `expr-call`
with captured lists: empty, singleton and growing inputs, retained pool
snapshots, invalid arguments, and the internal rejection of a list from
unrelated pool storage. `compiler-ctfe-captured-list-owner` checks owner
selection under an unrelated retained binding and newer tail, retained,
owning or active pool cursors. Its follow-up shapes then append through the
captured head, tail, retained snapshot or active context and require the
constructed call and every live child to survive. The native
`comptime_captured_list_builders.tl` fixture reaches the same path from public
macros with a binding-clause prefix, which captures the trailing operands as
the prelude `for` body does; it composes nested macros, list inspection, begin
bodies, quasiquote splicing and reuse of an operand list after a call at
opt0/1/2.

## Late clone helper syntax

`compiler-lower-missing-declaration-macro-diagnostic` checks nominal clone
lowering without the clone prelude, a generated missing macro, an ordinary
unknown macro and a function used as a declaration macro in Linux and Windows
modes. All retain source spelling and available location; ordinary declaration
macro expansion also retains E0501.
Keep the valid `compiler-lower-clone-source-with-prelude` cases alongside it.

`compiler-clone-late-tail-template` evaluates the stdlib producer's actual
self-tail template with both boxing choices and requires ordinary syntax.
Synthesized clone helpers are installed after macro expansion, so a macro call
in their body otherwise reaches the native linker as an unresolved function.
The test uses the shared AST child traversal and adds no list-shaped schema to
the repository's zero-cons corpus.

`compiler-clone-boxed-production-tail` reuses the optimizer's existing
`OptNonnegPhis` type for empty, single and 30,000-element clones. It validates
every element after source-arena retirement and checks tail mutation isolation.
The three `clone-boxed-production-tail-opt{0,1,2}` public-tool cases compile,
link and execute both clone tests on Linux and Windows without a test filter.

## IR sequence borrows

The existing IR type, optimizer, lowerer, liveness and register-allocation
smokes exercise `compiler-ir-*-seq-borrow` through read-only consumers.
`ir_sequence_borrow_bounds.tl` checks valid instruction and offset phi reads,
negative and past-storage indices, and empty block storage at opt0/1/2.
Bounds are physical; callers still prove the logical live-prefix index and end
each borrow before slot mutation or source-owner retirement.

## Compiler arena ownership

`compiler_driver_base_transients_smoke.tl` checks lazy lower scratch/IR roots,
fresh-driver isolation while another job has live arenas, growth beyond the
initial chunk, controlled-error cleanup, release while a different arena is
current, opt-level retirement, repeated release and reuse. The post-lower owner fixture preserves both jobs' alias facts,
releases only A's scratch, and reads B's scratch afterward while A's escaped IR
stays live. Run these at opt0/1/2. Lower-test helpers that keep function IR copy
it into their test arena before releasing the source lower owner; an extracted
sequence must not outlive its arena. Keep buffered output alive through its
final render/write and preserve the mainless-module opt0 symbol check.
The reader-context smoke optimizes both jobs at opt0/1/2 with explicit
retirement authority and an unrelated empty reader pool installed. Opt2 must
clear A's lower-IR cell while B's source remains live, then clear B's cell;
post-opt cleanup is idempotent and both backends still emit identical assembly.
The optimizer's `optimizer-input-retirement-*` tests cover absent authority,
empty functions, all levels, and nested Func/Tuple/Array/Box/reference/lifetime
payloads beyond a pool segment with empty and conflicting ambient pools.
`backend-owned-object-payload-lifetime` checks returned Linux and Windows
object strings and rendered bytes after lower IR retirement and a subsequent
source compilation. It also retires the input arena of both shared literal
producers and checks exact String/Bytes records, including NUL/high-bit bytes
and empty strings. Package build/run fixtures consume opt0 object images after
that retirement boundary; the direct-object retention bound stays unchanged.

`compiler-ast-context-dedup-half-load` in `src/tests/compiler_ast_types_smoke.tl`
checks explicit type-index growth with an installed decoy, colliding hashes,
caller-arena retirement and reset/reuse. Run it at opt0/1/2. The paired
`compiler-ast-context-dedup-max-capacity` test temporarily lowers the existing
capacity bound for a small real table and restores it before assertions.


`src/tests/scan_storage_growth.tl` exercises geometric lexer and reader
growth. It checks every token payload and position across growth against a
fixed token-buffer budget, nested reader builders while the pool grows,
post-growth lexer/reader failures, empty and successful reuse, and transient
caller retirement. Run its inline tests at opt0/1/2. The required
compile-profile gate runs them with `--cfg compile-profile` too.
The compiler-check smoke's loader suite covers cached imports and session
resets, while the compile-profile gate verifies scratch owners are zero at
load handoff and retains the separate reader-origin lifetime contract.
The same storage tests cover post-handoff spanned rows and live builders,
retirement while their owner is current, reset back to shared growth, and
malformed/empty reuse. With `--cfg compile-profile`, the growth test reconciles
the process live-byte delta with the replacement owner's bytes, so leaving the
old owner allocated fails even if its rows remain readable. The selfhost profile
probe bounds retained-reader storage before final compaction to 1.25 times the
live row payload.

Literal classification and contextual numeric checking must read expression
children from the caller's pool. The `tc-literal-expression-pool-isolation`
inline test in `src/tests/compiler_typecheck_core_tests.tl` gives three pools
identical node IDs
but different literal kinds and source positions, installs an unrelated owner,
and checks integer/f32 results plus f32 overflow rejection. It also checks
that an active compatibility pool context does not redirect typechecker reads,
and the canonical/sparse-view span oracle. Keep those owner and source-view checks when changing literal walkers or
their lowering callers; an unwrapped literal alone cannot detect a wrong-pool
read.

The call-argument type memo keys a body fact by the immediate payload of the
first source view under the argument's expansion wrappers, and both the owning
and an unrelated pool can hold a valid view at the same ID. The
`tc-call-arg-fact-key-pool-isolation` inline test (same module) builds two
pools with seven
colliding IDs, seeds distinct types under the owning and decoy-selected keys,
and calls `tc-call-arg-expr-type` with an unchanged context and argument across
pool installs in recording and consuming modes. It covers direct and nested
views, expansion chains, a non-view whose decoy twin is a view, the explicit
compatibility route, and a clear followed by a restarted recording. Run it at
opt0/1/2. A key-only check is not enough: keep the seeded-fact phases, which
show that a wrong owner selects another entry rather than merely missing.

Compiler state must be allocated in an owner whose lifetime covers every state
transition that can occur before the last use. Use these operational classes:

| State | Required owner and release boundary |
| --- | --- |
| Transient walk data | The current scratch arena; retain nothing across its rewind or destruction. |
| Retained phase data | A dedicated phase arena; it may cross scratch rewinds, but reset or destroy it only at the documented phase boundary after all consumers finish. |
| AST/type nodes | The installed `AstNodePoolContext`; allocate through the pool APIs and release with that pool context. |
| State crossing pool installs or intern resets | A separate arena created once for the required lifetime. Never rewind or destroy it during that lifetime; clear the collection logically by rebinding or resetting metadata. |
| Growable index over such state | A generation arena holding only the current arrays (slots of descriptors, hash index). Growth builds the replacement in a fresh arena, publishes it, then destroys the old one. The values the arrays point to stay in the lifetime arena, and no reader holds a generation's arrays across a call that can grow them. The IR label table (`compiler-ir-label-generation-install!` in `src/compiler_ir_types.tl`) is the reference. The structural interner's record columns and map follow it (`intern-structural-table-grow-records!` and `-grow-map!` in `src/compiler_intern.tl`); every persistent reset releases both generations before it rewinds or replaces the owning arena, and every owner teardown releases them (`intern-compat-state-release-structural-generations!`) before it destroys that arena. |

Do not allocate unrelated long-lived sidecars by temporarily switching to
`node-pool-base-arena`. An `AstNodePoolContext` captures the base-arena head.
Pool growth advances that moving chain head, but a later
`ast-node-pool-context-install!` of an older capture restores the older head.
Allocations in segments added after the capture can then become unreachable;
the fact that a global, map, or cache binding still contains their addresses
does not keep those raw segments alive.

`cfg-label-index-survives-source-pool-reset-and-reuse` in
`compiler_optimize_tests.tl` retains a live index across partial/full source
interner resets, reused source slots and a second index build. IR labels have
their own spelling lifetime; the index's arrays must remain in a live caller
arena. The test restores the ambient interner before releasing its isolated
state. Run it at opt0/1/2.

The intern persistent arena is not a substitute. A floor reset through
`intern-compat-state-persistent-arena-reset-to-floor!` rewinds allocations
above its mark, and a full reset replaces or destroys the arena. State that
must cross either boundary needs its own owner. Allocate the initial collection,
owned keys/values, and every capacity growth in that same dedicated arena, or
put the growable arrays in a generation arena as described in the table.
Restore the caller's active arena after each operation, but never reclaim the
dedicated arena until its complete required lifetime ends.

Standalone load sessions give embedded provenance and dotted-path payloads
separate session-owned arenas. These survive caller scratch rewinds, and their
reset boundaries clear the dependent maps/slots before releasing storage. Path
lookups copy both hits and misses into the caller's arena. Explicit provenance
operations use the intern domain bound to their `CompilerLoadSessionState`; an
installed decoy must not change that identity. The load self-test exercises
colliding A/B IDs and an installed decoy whose pool length and table identity
remain unchanged.

`test --batch` and package test entries own their compiler pool context, load
session and serial typecheck job. Their common finish boundary consumes the
scalar result, clears aliases while the entry is alive, retires private storage,
restores the parent selectors, then destroys the entry owner. A reusable cache
reset is insufficient here: aggregate-layout payloads normally wait for another
lookup, and empty-env resets can recreate the scoped-environment arena. Terminal
job retirement releases those owners after the last reset.
`test_cli_entry_memory_smoke.tl` exercises twelve ordinary inline entries in
one process and checks retained bytes after four warm-up entries. The small
leaf still compiles and executes its test each time; all eight measured entries
must retain at most 1 MiB in total. This also covers repeated unbound-name
snapshot recording and clearing after implicit global storage copies acquire
program lifetime; the snapshot container must be reused. The native integration
manifest runs it on both hosts. `test_cli_entry_state_smoke.tl` checks parent selectors and explicit intern
bindings after success/error scalar results, and verifies copied cache hits and
misses survive cache reset after the caller scratch arena has been destroyed.
Macro hygiene retirement requires no active root; the debug runtime permits that explicit
retirement while continuing to reject ordinary reset/destroy of protected roots.
`scripts/verify-compiler-arena-debug.sh` builds a test-enabled emitter (which
contains the optional debug templates) and checks all fifteen native fixture
operations on each CI host, including grown-owner retirement and invalid handles.

`compiler_ast_types_smoke.tl` checks retained type-pool stamps against
independent contexts, append growth, global installs, truncation, shallow views,
old-cursor ID reuse, types-only copying and storage retirement. Removing the
revision change, shared append high-water check or actual cell-identity check
must make its dedicated stamp witness fail. A copied type prefix has a new
authority, even when its numeric type IDs are unchanged.

Explicit compiler invariant failures use the dependency-free `compiler_abort`
leaf with a static message identifying the table and caller. Do not call the
site-free `tl_oob_abort` from non-test compiler code. `check-tl-lint.sh` checks
the source token stream and exercises a split-call rejection probe while
allowing comments, strings and extern declarations. The native manifest runs
`compiler_abort_sites.tl` at opt0/1/2 on both hosts: intern IDs, structural
sessions, SSA rename checkpoints and token access each have an exact stderr
oracle and managed exit 134, with a successful table-use control. The same
fixture exercises type-pool revision exhaustion and append after retirement.
These explicit failure paths call the out-of-line runtime diagnostic; message
formatting and allocation must not be introduced on successful table reads.

For a regression test of retained mid-walk state, exercise the invalidating
sequence rather than only testing insertion and lookup in one context:

1. Capture an older node-pool context, allocate and force at least one regrowth
   of the retained collection while a scratch arena is active, then install the
   older context.
2. Run the intern floor/full reset boundary that the state promises to cross,
   where applicable.
3. Read every retained entry and force another insertion/regrowth after the
   boundary; compare the result with an equivalent fresh-state run.
4. Run the reproducer on Linux and Windows. Keep poison/debug configurations as
   additional diagnostics, not as a replacement for the semantic assertions.

The production incidents and measurements are recorded in
[#5458](https://github.com/JoNil-Botta/typelisp/pull/5458) and
[#5474](https://github.com/JoNil-Botta/typelisp/issues/5474). The opt-in guard
that should fail at an invalid reset/destroy/install operation is tracked in
[#5510](https://github.com/JoNil-Botta/typelisp/issues/5510).

## Coverage layers

### Ownership core and independent model

`compiler_typed_occurrence_tests.tl` tests the bounded selected-occurrence
store through `src/tests/compiler_typed_occurrence_smoke.tl`. Build the driver
with `--stdlib-root src --stdlib-root stdlib`; success exits 42. It covers
contextual occurrences sharing an AST ID, generated literal payloads, ordered
callee/argument children, nested rollback and slot reuse, query isolation,
resolver and interner identities, revoked leases, cumulative work, terminal
resource/serial exhaustion, and charged array growth with retained handles.
Mutation cases also reject negative/overflowed child spans and malformed logical
table extents before indexing storage.
Typed-place controls additionally cover nested dynamic-index child order,
formation versus value categories, exact acquisition identity/type, mismatched
projection containers, foreign owners, restored-slot reuse, nested rollback,
growth with retained place handles, Query refusal and forged cyclic paths or
scalar categories. These authored place facts are not source projection or
ownership-admission coverage.
Projection source handles are validated too; forging their serial is rejected
before a source payload is exposed.
This exercises producer plumbing, not ownership admission. The native manifest requires this
smoke on both hosts at opt0/1/2; the compiler manifest includes the module and
its tests.

The source fixture `ownership_certified_scalar_control.tl` covers captured
operand values, signed comparison, loop-local initialization, continue/break,
short-circuit effects, early return and unsigned ABI arguments through the
ownership graph and the ordinary lowerer (exit 42 on both hosts at opt0/1/2).

`compiler_ownership_normalize_tests.tl` exercises the primitive selected-node
normalizer through `src/tests/compiler_ownership_normalize_smoke.tl` (exit 42).
The native manifest requires both hosts and opt0/1/2. Tests cover distinct
canonical scalar types, owned provenance after lease retirement, ordered
temporaries, short-circuit initialization and shadow identities, normal and
return edges, binder read/write type agreement, unique local declaration
initializers, duplicate executable edges, malformed child spans, stale owners,
resource limits and unsupported dead forms. They use selected-occurrence
fixtures; broader source producer coverage and lowering admission remain
separate obligations.
Isolated production mutations removing the repeated-occurrence guard or
forcing an `and` RHS to execute are rejected by the focused expectations with
normal exit 1; compilation failures or crashes are not mutation witnesses.

The `selected-inference-transactions` inline test in
`tests/compiler_typecheck_core_tests.tl`, also called by the typechecker smoke,
exercises the real selected inference entry: distinct contextual types for one
AST ID, generated values, chosen child order, failed and unrepresented parents,
query isolation, terminal resource failure, and a decoy installed interner
rejected before a bogus expression ID is read. Grown compatibility and mirrored
pool cells verify that Query bounds follow the canonical reader without
mutating the saved cursor, reject wrong source owners/generations, and cannot
relax Capture's exact leased bounds. The API self-test and
`tests/integration/selected_inference_dotted.tl` preserve the original ID route
for hygienic dotted reads/assignments and generated lambda bodies. The latter
runs on both hosts at opt0/1/2. These tests do not claim full source normalization
or successful ownership certification.

The same producer smoke exercises the live-lease normalizer hook: primitive
success, structural result-type mismatch, source-located uninitialized read,
hard resource failure and explicit Unsupported migration. Canonical return
compatibility runs before this hook; the existing exact return-mismatch API
test preserves that diagnostic. Legacy source admission still runs, and the
checked primitive body is not yet retained into lowering.

The lexical producer controls pin the actual plain/unsafe lookup winner,
shadowing, persistent fallback, distinct carrier epochs and reused slot
generations. Parameter associations are created by the canonical bind loop;
the selected Read names that parameter's typed binder. A foreign carrier with
the same ordinal/generation, an old winner after restore, a reused unmapped
slot and a wrong body owner are refused. Epoch/generation exhaustion is sticky
and fails before source access; MAX-1/MAX controls also catch exhaustion caused
by post-inference scope restoration. `begin` tests ordered children with a
shared AST ID but different contextual types and preserve checking of a tail
after an early return. `let` controls retain ordered initialization, contextual
types from shared syntax, nested shadowing, repeated reuse of a restored slot,
exact selected initializer origins, and successful owned-IR normalization.
Unsupported parents and canonical initializer errors discard their retained
children and restore scope; the inline test counts one inference per
initializer. Assignment controls retain the pre-RHS winner across RHS-local
shadowing, infer that RHS once, and refuse to invent a binder for persistent
targets. Return controls distinguish the canonical contextual type from
intrinsic `Never` through selected let/begin/if, retain explicit return operands,
normalize the resulting control flow, and preserve missing-function/type-error
diagnostics. Divergent binary operands and initializers stay explicitly
unrepresented and roll back their retained children.

Primitive producer controls also cover contextual/plain unary operand types,
overflow and invalid-operator rollback, and noncontextual conditionals with
distinct occurrences for shared branch syntax. Plain binary comparisons retain
ordered operands and their canonical types. Literal-left integer/float narrowing
and float fallback retain exactly the selected children, binders and source
origins. Initializer counters pin one inference for a chosen probe and two for
the canonical fallback/retry. Rejected fallback rolls everything back without
refunding work or serials; resource exhaustion cannot become legacy success.

Tuple projection producer controls bind a nested tuple parameter through the
canonical parameter loop and inspect its exact selected place path. Copying a
scalar sibling of a Box and moving the Box each retain only formation and
acquisition occurrences, with no read of the whole tuple. Query type/error
parity, out-of-range rollback and a successful projection under an abandoned
parent are checked. Aggregate/place normalization remains explicitly Unsupported;
these controls do not certify aggregate ownership.
The public tuple fixture also reads the Copy sibling after moving its nested Box;
the safety fixture pins a repeated Box move to the second move's exact location.

Array producer controls cover nested fixed and dynamic arrays, distinct selected
index children for reused syntax, exact index and per-projection origins, fresh
index-local binder generations and one canonical inference per index. An invalid
receiver still checks its index before receiver classification, matching the
canonical diagnostic order. Invalid indices and unsupported annotation/borrowed
receivers restore selected places and child/binder counts. These source facts
remain outside the current scalar normalization and lowering certificate.

`tests/integration/macro_try_operand.tl` covers recursive macro expansion under
`try`, including a macro-generated try, hygienic caller locals, single operand
evaluation and early error propagation. The native manifest requires both hosts
and opt0/1/2. This fixes expansion before typechecking and does not claim a
selected ownership producer for try itself.

The `tc-dotted-identity-boundary` test also runs through the typechecker smoke.
It pins competing use-site and definition-site import aliases, valid variant
lookup, exact unbound diagnostics, and rejection of local/composite identities,
unpublished interner slots, malformed global payloads, foreign owners and stale
generations before raw dotted-name metadata is read.

`compiler_ownership_core_tests.tl` tests the standalone typed ownership graph
through `compiler_ownership_core_smoke.tl`, registered in the native manifest
for both hosts at opt0/1/2. Cases cover nested partial moves, exact
reinitialization, disjoint fields, distinct shadow bindings, joins, repeated
loop iterations, break/return/abort edges, retained exit uses and Copy versus
MoveOnly transfers. Malformed owners, generations, revisions, types and place
forests fail structurally; unclassified operations fail even in dead blocks.
The tests distinguish semantic rejection from resource exhaustion and check
deterministic dumps, identity widths and source-provenance framing.

`compiler_ownership_loan_tests.tl` adds shared/exclusive capabilities, nested
reborrows, disjoint access, last-use expiry, explicit ending, diamond and loop
liveness, and malformed loan identities. Its registered native smoke runs at
opt0/1/2 on both hosts. These authored graph tests distinguish initialized-place
failures from loan conflicts and require bounded resource failures to remain
failures. Additional controls cover direct and sibling conflicts, three-deep
grant chains, Copy/Move and Copy-consuming operations, terminator reads and
EndLoan demand across a backedge. Direct liveness observations require a
parent to remain live before its definition when an existing child is live;
overall rejection alone could hide this behind a zero-iteration path. Dead
shared writes and exclusive children of shared parents fail structurally.
An isolated mutation restoring unconditional definition kill builds and makes
the direct liveness expectation fail with normal exit 1.
Resource cases reach the loan solver itself: a fixture requires exactly 48
reserved cells (40 fails), eight points exceed a seven-point limit, and a
50-loan/300-place/1,000-instruction graph completes under default limits.
Observation controls pin owned row dimensions and the state before/after
Borrow, and require the first semantic error to remain sticky when diagnostic
inspection continues. A fixture accepted with 38 ordinary state cells needs
60 cells for inspection, including a per-point failure-kind row; 59 returns
Resource with incomplete observations. Earlier and later loan errors both
remain visible in the per-point row even when the first diagnostic is retained.

`compiler_ownership_cleanup_tests.tl` runs through the cleanup smoke at opt0/1/2
on both hosts. Authored cases pin exact retained dependencies across transfer,
loan conflicts after transfer, rejection of simultaneous root aliases and
successful reuse after Leave, missing owned-root declarations, and ordered
initialization/scope diagnostics with all per-point failure bits retained.
Metadata controls reject ordinary containers of owned fields and incomplete
cleanup plans, while admitting ordinary Copy fields and context-only Copy
cleanup hooks. A body whose structural validation fits 64 cells must still fail
its larger cleanup expansion with Resource; default limits admit its valid
control. Dump checks require type ownership, exact contracts, parent identities
and retained operands in version 3. Registration describes required coverage,
not proof that every host run has completed.

`compiler_ownership_normalize_tests.tl` includes structured scalar While,
Break and Continue cases through the registered normalizer smoke. Each selected
condition/body occurs once and must become a CFG cycle. Tests pin nearest-loop
targets, nested target restoration, repeated Copy declarations, outer Assign,
zero-iteration and first-entry initialization, and malformed/dead control forms.
Isolated mutations of the repeat edge and lexical target restoration must build
and fail their exact witnesses normally; compiler rejection or a crash does not
count. The selected-inference producer smoke additionally runs twelve source
loop cases against the shared Query/Capture checker: nested controls, repeated
syntax with distinct binders, single initializer inference, scope restoration,
unsupported/error rollback, and exact condition-before-body failure ordering.
Invalid conditions prevent a later invalid initializer from being checked.
These controls do not claim complete source normalization or lowering admission.

`tools/ownership-model/README.md` documents the independent concrete model,
finite bounds and separate production comparison adapter. Run
`TYPELISP_BIN=<compiler> scripts/verify-ownership-model.sh` for the bounded
native opt0/1/2 campaign and retained resource/identity reports. These tests do
not exercise a production AST normalizer: the core is not yet the authoritative
source ownership checker. Native fixture construction itself exercises
aggregate value copies and borrowed enum descriptor payloads; a compiler bug
there must fail the campaign rather than count as an ownership rejection.

### Safety rejection oracle

`scripts/verify-safety-corpus.sh` requires a normal checker exit of 1 and a
structured, source-located diagnostic for every `check-fail` row. The expected
substring must occur in diagnostic text or metadata, not a location path or
an echoed source line;
its primary location must belong to the expected source. The fourth manifest
field can name another source for imported-body errors, or pin
`source:line:column` for an intended operation. `-` selects the fixture source.
Pin exact operations when adding safety regressions; a located error somewhere
else in a large fixture is weaker evidence.

A matching diagnostic followed by a crash, timeout or killed process fails the
gate. `rejections.tsv` beside the retained output records exit status and the
classification: accepted-invalid, rejected-invalid, wrong-diagnostic,
malformed-output, compiler-crash, or infrastructure-resource-failure. A kill
status alone cannot distinguish OOM from an external kill, so both remain
resource failures. Empty, duplicate and incompletely executed manifests fail.

The gate always runs planted outcome and diagnostic mutations, including a
child that emits the expected diagnostic and then aborts. Run
`scripts/verify-safety-corpus.sh --self-test` for those fast oracle tests without
building a compiler. These tests validate the harness; they do not establish
coverage of compiler ownership obligations.

`aggregate_local_value_snapshot.tl` exercises local binding and assignment
copies from nested projections and value-producing wrappers. It also preserves
Box identity during a move, distinguishing a shallow storage transfer from a
deep clone. `borrowed_pattern_descriptor.tl` distinguishes borrowed dynamic-array
descriptor handles from their enum, tuple and fixed-array storage slots, with
String, Box and inline-array controls for each pattern form. These are shared
patterns; mutable borrowed patterns are outside the supported syntax.
`aggregate_parameter_storage.tl` checks private by-value struct and enum
storage through direct, indirect, tail-position and captured-closure calls.
It checks caller values after callee mutation, a mutable-reference control,
and Box identity through moved aggregate parameters and returns.
`tail_call_aggregate_storage.tl` keeps caller-owned aggregate and projected
reference storage alive across tail-position calls, with a scalar forwarding
control. These native-manifest rows run at opt0/1/2 on Linux and Windows;
agreeing optimization levels must still produce the independently specified
exit 42. Backend module tests also author raw tail-call IR directly, testing
named, extern C and indirect closure fallback on both target ABIs. Identity
forwarding tests retain the spill-free scalar case and reject modified,
unknown or narrow operands and repeated snapshot destinations.

`pointer_eval_order.tl` fixes expected values for pointer offset, pointer writes,
atomic/volatile stores, fetch-add and CAS when later operands rebind an earlier
operand's source. `array_set_eval_order.tl` covers fixed/dynamic arrays, borrowed
Slices, direct and materialized aggregate RHS values, and zero-size elements.
`aggregate_assignment_storage.tl` keeps local storage identity when the RHS
reassigns a selected field's receiver and snapshots the final aggregate
constructor operand before destination writes; packed locals, tuples, enums,
global storage and shallow Box transfers provide controls. `array_store_place.tl` grows the
captured dynamic descriptor during the RHS, including through nested inline
projections, and distinguishes descriptor rebinding from descriptor mutation.
Wrapper controls merge mixed fixed/dynamic places and unequal dynamic root
layouts, preserve a copied Let local's private home, and check exact condition,
selected-arm, index and RHS effect order. The Return arm must retain its exit.
`array_store_scope.tl` adds scalar, nominal and borrowed match receivers,
resource cleanup before index/RHS evaluation, arena scopes, fresh literal/call
receivers, clone-out scopes and returned mutable-reference controls.
The lower module's store-place test pins the initial and commit-time dynamic
bounds checks, with a single-check fixed-array control.
The two `array_set_*bounds_order.tl` rows require a bounds abort with empty stdout
before the RHS prints its marker. The native manifest pins all three
optimization levels. Array receiver reassignment during a read is not evidence
of by-value array copying: that operation's place semantics must be resolved
separately.

`compiler_ir_types_smoke.tl` tests the shared tail-transfer frame-exposure guard
against linked, dense and mixed blocks, both storage producers, spare slots and
malformed logical lengths. The optimizer's `tailrec` test authors frame-derived
arguments through alias/Gep/cast instructions directly, so a lowerer refusing
the source form cannot hide an unsafe optimizer rewrite; the scalar control
still converts to a loop.

Raw buffer boundary tests for #7945 are described in
[`../docs/ownership-ir.md`](../docs/ownership-ir.md#raw-buffer-boundary-seed-7945).
Invalid-pointer fixtures are check-only. Native forged-length witnesses use the
guarded wrappers and require the exact deterministic abort, with separate valid
full/empty and cleanup-count controls.

`regalloc-assignment-table-empty` checks empty and sparse assignment tables,
every occupied position through the last slot, ignored out-of-range inserts,
replacement, repeated unassignment, copying and overlays. Both explicit spills
and register homes count as assignments. The native register-allocation
self-test runs the same cases; exercise it at opt0/1/2 when changing presence
queries or assignment-table mutation.

### Module-local self-tests

Put small structural checks in the owning module's `*_tests.tl` companion (for
example `compiler_parse_core_tests.tl` beside `compiler_parse_core.tl`), so the
shipped compiler does not carry them. These are usually functions named
`*-self-test`, with focused boolean helpers when that makes the assertion
readable.

Current examples include:

- `compiler-parse-error-tests-ok?` and `compiler-parse-smoke` in
  `compiler_parse_core_tests.tl`
- `compiler-symbols-self-test` in `compiler_symbols_tests.tl`
- `compiler-typecheck-self-test` in `src/tests/compiler_typecheck_tests.tl`
- `compiler-regalloc-self-test` and `compiler-backend-self-test` in
  `compiler_regalloc_tests.tl` and `compiler_backend_tests.tl`
- `compiler-optimize-self-test` plus the pass-specific optimizer self-tests in
  `compiler_optimize_tests.tl`

Test-only helpers belong in these companions (or under `src/tests/`), not in
the production modules they exercise.

`compiler-field-type-indexed-bounds` checks first, middle and last fields of
different types, empty field storage, signed index extremes and a registry
handle whose child is past the owning struct. The symbol smoke runs the same
checks alongside lifetime-bearing fields and shifted declaration owners.

Prefer small hand-built fixtures and deterministic structural assertions over
large golden strings. A runnable self-test returns `42` on success. Failures
should be specific enough to identify the broken layer; using `panic` with a
short module-prefixed message is normal when a boolean helper fails. Aggregator
self-tests must name each failed check instead of mapping predicates or child
self-tests to magic exit codes. A leaf self-test may temporarily retain a
numeric status when changing it would obscure a large fixture, but its caller
must print the leaf's name and returned/expected status before failing.

### Smoke drivers

A `*_smoke.tl` file is the runnable wrapper for one or more module-local
self-tests. It should contain little logic: import the module, call the
self-test, and return `42` only when the checks pass. Examples include
`compiler_parse_smoke.tl`, `compiler_lower_smoke.tl`, and
`compiler_backend_smoke.tl`.

Smoke drivers and their fixtures live under `src/tests/` (a reserved package
test directory, excluded from the source/closure scan). They are built and run
as exit-42 integration cases by `tests/integration/native.manifest`. Place a
new smoke beside the others in `src/tests/`; import source modules by canonical
dotted identity, such as `compiler_parse_core`. A direct repository-root run
must include `--stdlib-root src`, matching the native integration and
compile-manifest runners.

Use a smoke driver when the module is main-less or when CI needs to compile and
run the module through the TypeLisp executable boundary. A smoke may instead
hold `(test ...)` forms that the inline-test gate runs, as
`compiler_optimize_smoke.tl` does; it then has no `main` and no manifest row.

Heavy smoke wrappers may be listed in a native manifest row's optional last
`suite-members:` field. A suite compiles shared compiler modules once, then
launches its own binary with one named child argument per member so mutable
compiler globals retain the fresh-process behavior of standalone drivers. Keep
the original driver as a thin runnable wrapper and place shared test bodies in
a main-less `src/*_tests.tl` helper. Manifest validation requires every suite
member to remain an executable `src/tests/*_smoke.tl`, be named by the suite
source, and not also appear as a standalone manifest source.

### Pointer-proof source fixtures

`compiler_pointer_proof_smoke.tl` lowers source programs through the requested
semantic-evidence boundary. It compares direct-pointer and integer-round-trip
returns whose machine IR is identical, checks distinct uses and conversion
locations, and rejects missing or unsupported evidence. Its requested/ordinary
assembly comparisons cover opt0/1/2 and Linux/Windows lowering, including
pointer casts, offsets, binding mutation, helper calls, recursion and nulls.
These fixtures inspect generated programs; they do not execute foreign pointer
returns. When extending this boundary, preserve the ordinary lowering workload
and measure both disabled and requested paths under the compiler performance
protocol. Job isolation tests must read earlier evidence after a later job and
after source/type/interner retirement, then reject a retired proof owner.
Parse/type failures must consume the requested owner before any later job can
reuse its copied source locations.

### IR-text fixtures

Optimizer, backend, register-allocator and liveness fixtures state their IR as
the `typelisp-ir v1` text that `--dump-ir` prints, read back by the test-only
`compiler_ir_text.tl` (`irt.instr`, `irt.instrs`, `irt.blocks`, `irt.func`,
`irt.program`); state new optimizer and backend fixtures this way. Backend
fixtures give register assignments as one-line `reg-homes` specs such as
`"%4=%xmm3 %6=spill:-16 %7=%r12/%r13"`, and check emitted assembly with
`asm-has?`, `asm-lacks?` and `asm-ok?`. Fixtures the text cannot express stay
hand-built: symbols interned outside the IR symbol table (runtime builtins,
globals), total-enum switches and char values (the reader's header lists what
the renderer drops).

Register-plan ownership has source-local inline tests in
`compiler_regalloc_tests.tl`. `compiler-reg-returned-plan-profile-owner` checks
that resetting metrics through a returned plan reaches the caller's original
owner on both sides of the scratch budget.
`compiler-reg-retained-plan-survives-later-planning` preserves a Linux
plan across repeated Windows planning calls and compares its retained homes to
an independent snapshot. `compiler-reg-analysis-owner-boundary-homes` widens
only unused frame space across the budget boundary; Linux and Windows homes
and post-plan trace reasons must match the small fixture after the scratch
owner retires. `compiler-regalloc-self-test` runs its liveness-census check
only in a build with `--cfg test`; that flag alone does not run source-local
inline test declarations.

The root-segment union tests compare gathered/sorted unions against the former
insertion fold on deterministic generated member sets. They cover empty and
single-member classes, unsorted and nested ranges, shared endpoints, genuine
holes, invalid or missing parent entries, absent segment rows and inactive
members. Exact snapshots preserve the original member arrays; a golden case
pins endpoint sharing, one-position gaps and the upper i64 boundary.

### src/ reachability

The package follows the standard layout: `typelisp build` resolves the default
`src/main.tl` entry (no explicit `entry` in `typelisp.pkg`), and every top-level
`src/*.tl` is reachable from `main.tl` except:

- the main-less `src/*_tests.tl` test companions, such as
  `compiler_backend_tests.tl` or `compiler_surface_tests.tl` (the latter runs
  only through `tools/compiler-surface-ast-smoke.tl` with
  `--cfg compiler-surface-selftest`);
- test-only infrastructure, such as the `compiler_ir_text.tl` IR text reader;
- modules only a tool imports (`compiler_embedded_stdlib_tlci_encoder.tl`,
  `doc_site_doc_bridge.tl`);
- groundwork that an open issue chain builds on and that, until then, only its
  own tests reach: the stack-traffic fact boundary (#7236), the incremental identity/trace/graph/planner modules (#7025), the SFrame v3 codec,
  the COFF import-member writer, the x64 executable template selection
  modules, the git client cores and `lint_fix_plan_core.tl`.

### Incremental query planner

`compiler_incremental_plan_tests.tl` drives a synthetic serial executor and a
clean recomputation oracle. It checks exact graph bytes, stable outputs with new
result keys, changed outputs, added/removed children, admission misses, diamonds,
multiple roots, reordered frozen tables and fresh arenas. Its mutation table
includes source, imported surface/resolution, target/cfg/profile, compiler build,
stdlib/package provenance, macro implementation/generated output/declarations,
source fallback and negative lookup observations. Hostile feedback and budget
tables verify that errors expose no complete graph and retain a bounded scalar
terminal event.

`compiler_incremental_plan_stress_tests.tl` checks unchanged, sparse stable,
output-changing, dynamic and all-changing star graphs. Every batch is submitted
in reverse order. The synthetic executor uses indexed node lookup and one direct
registration per recomputation, so fixture work does not add a quadratic scan.
The chain fixture checks success at the configured suspension-depth limit and
a typed resource failure one node beyond it, with no complete graph exposed.
Its reusable stress driver reports planning/finalization milliseconds, scheduler
steps, actions, index comparisons, child requests, suspension peak, allocator
total/peak byte deltas, conservative owned-byte charges, and encoded/event bytes.
Large schema-bound experiments retain the same edge/node schema limits with
explicit finite trace sorting and metadata budgets; all process trees also use
the OS memory cap. Allocator instrumentation uses the existing `compile-profile`
cfg when compiling a standalone stress driver.

Run the companions with a freshly built compiler and the standard roots:

```sh
typelisp test src/compiler_incremental_plan_tests.tl --stdlib-root stdlib --stdlib-root src
typelisp test src/compiler_incremental_plan_stress_tests.tl --stdlib-root stdlib --stdlib-root src
```

Imported test companions supply fixture helpers; their test declarations do not
join an importing module's harness. The normal inline gate discovers both files.
The pure planner's next production consumer is #7025; these tests do not claim
CLI cache, store hydration, diagnostic parity or publication integration.

### Inline tests

Top-level `(test name body...)` items are source-owned executable checks; the
`typelisp test` command, its flags and its exit codes are described in
[`../docs/testing-and-bootstrap.md`](../docs/testing-and-bootstrap.md#tests-and-documentation).
Ordinary `compile`, `run` and `build` type-check the inline tests of the
sources they own and then drop them from production codegen.
`typelisp test <file.tl>` runs only the tests owned by the requested source:
imported files provide runtime declarations but do not contribute their own
tests to the harness.

Package integration discovery skips the reserved `tests/format_golden/**`,
`tests/golden/**`, `tests/inline/**`, `tests/no-libc/**`, `tests/public-tools/**`,
`tests/safety/**`, `tests/spmd/**`, and `tests/tlci/**` fixture corpora. When
`tests/integration/native.manifest` exists, package discovery also leaves
`tests/integration/**` to the explicit integration runner. Dedicated
verification scripts own those files.

Package-wide source discovery for commands such as `check`, `fmt`, `lint`, and
`doc` treats directories named `tests` as reserved package test/fixture roots
instead of ordinary package sources. The `typelisp test` command owns
package-local `tests/` discovery through the integration-test path above.

Use inline tests for behavior that naturally belongs next to the declarations
under test. Import `stdlib/test.tl` for assertions such as `assert-i64-eq`.
Keep smoke drivers for existing compiler-module self-tests until those modules
are intentionally migrated. [The repository inline-test
gate](#repository-inline-test-gate) discovers every inline test, so adding one
needs no manifest update.

Inline-test reachability must preserve global storage roots before typechecking
field projections. `tests/inline/global_field_reachability.tl` covers nested
fields, initializer dependencies, imported helpers and hygienic macro
references. Run it at all optimization levels, alongside the harness retention
tests in `test_cli_core_tests.tl`, which also prove unrelated globals remain
pruned. The intern source-session tests exercise dotted-root lookup through an
inactive owner. The harness normalization regression installs a colliding
macro-global decoy pool and checks that the captured owner still determines the
source name.

### Selfhost compile manifest

Compile/symbol smoke coverage is driven by
[`compile_manifest.txt`](compile_manifest.txt), checked by
[`../scripts/verify-selfhost-compile-manifest.sh`](../scripts/verify-selfhost-compile-manifest.sh).
The runner compiles each manifest case with an already-built TypeLisp compiler,
rejects generated `# TODO` assembly, applies the case's `main:` label policy,
and checks the case's codegen markers (calls that must survive, runtime
helpers, symbols that must not be emitted) in the emitted assembly. Label
existence alone is not a marker: a compile case already fails when the module
does not compile, and command behaviour belongs to the CLI gates.
`_tl_foo` and `call _tl_foo` markers are logical symbol
markers, so both expectation modes accept direct labels such as `_tl_foo` and
emitted module/path-qualified labels such as `_tl_calc_foo` without changing the
manifest list. CI runs the manifest on the bootstrapped stage2 compiler with
`TYPELISP_COMPILE_MANIFEST_EXPECTATION_MODE=stage1` on both hosts; in that mode
symbol markers also accept compact selfhost symbol metadata. The default
`stage0` mode remains for standalone runs against the published seed.
Use `requires-stage0-mode|<reason>` only for a case that must remain seed-only
for a named, tracked blocker.

Staged cases cover integration drivers whose imports need temporary sibling
names, such as the `sym_i64_env` driver.

The runner compiles the manifest as `compile --batch` chunks: 16 entries per
chunk on Linux, a deliberate cross-entry retention stress, and one per chunk on
Windows for commit headroom. Chunks run in the bounded pool from
`scripts/lib-bounded-pool.sh`:
- `TYPELISP_COMPILE_MANIFEST_WORKERS` sets the number of chunks compiled at
  once (1-3, default 2).
- Each chunk runs under an enforced 4096 MiB cap and a 900 s timeout.
- Chunks are settled in chunk order. A failing chunk, or one stopped by its
  cap or timeout, fails the gate with its output.

A case's `contains`, `not-contains` and `count-at-least` directives are
checked together at its `end`, in one pass. One `grep -F -f` keeps the
assembly lines that hold any needle, any symbol needle's bare symbol, a
`main:`/`_tl_start:`/`# TODO` marker or a symbol-metadata row, and one awk
decides every directive from them, with the same fallbacks and the same
failure messages as a per-directive check. Every symbol regex requires its
bare symbol literally, which is what makes the line prefilter exact, so the
runner refuses a symbol needle whose symbol is not a non-empty
`[A-Za-z0-9_]` word.

Every run first executes the expectation self-test (each directive kind on
synthetic assembly, through each fallback route, with each failure message)
and the pool self-test (a fake compiler). `--self-test-pool` runs just these
two, without compiling the manifest.

### Scalar floating-point comparisons

Scalar `f32`/`f64` comparison predicates are selected once by
`compiler-backend-float-compare-reg-asm`, including register, memory, fallback,
and bool-return routes. An unordered `ucomiss`/`ucomisd` sets ZF, PF, and CF:
`=`/`<`/`<=` must exclude PF, while `!=` must include it. The current result
initialization and parity branch write only the planned result register and
preserve the comparison flags until `setcc`; integer-only flags reuse must not
absorb this sequence. Keep the exact sequence and register/spill/return tests
in `compiler_backend_tests.tl` together with
`tests/integration/float_comparisons.tl`'s integer-bit oracle, both-operand NaN
matrix, and evaluation counters. The native integration manifest runs that
fixture against staged source stdlib at opt0/1/2 and against the embedded
stdlib, on both hosts.

### Cross-Target Codegen Parity

Use [`../scripts/check-codegen-target-parity.sh`](../scripts/check-codegen-target-parity.sh)
to catch Linux/Windows drift before backend assembly. The script compiles a
small non-target-cfg corpus with `compile --emit-ir` for `linux-x86_64` and
`windows-x86_64` at opt levels 0, 1, and 2, then diffs the deterministic IR
summaries. It also fails if target-specific tokens appear in
`src/compiler_optimize.tl`, keeping the optimizer target-independent. A
separate target-cfg probe confirms that `compile --emit-ir --target` is actually
honoring the requested target.

The same gate runs the target-dispatch boundary guard,
[`../scripts/check-codegen-target-dispatch.sh`](../scripts/check-codegen-target-dispatch.sh),
first with `--self-test` and then against the tree. The design it enforces:

- **One shared x86-64 backend.** There are no Linux or Windows copies of the
  backend or the lowerer.
- **The lowerer's ABI shapes stay target-aware.** C aggregate classification
  legitimately changes the IR, so `compiler_lower*` modules may name targets.
- **Shared code reads facts, not targets.** Instruction selection, register
  allocation, object encoding, runtime composition and peephole code ask the
  target policy, the ABI tables (`compiler_abi.tl`), the object format or a
  runtime leaf for the fact they need: shadow space, SEH unwind, ELF or COFF, a
  register. They never test Linux or Windows themselves.
- **Platform choices sit in named places.** A target is mapped to its policy
  and facts in a few named policy scopes. A few named adapter scopes select a
  platform leaf (the runtime and object-image modules) or one of two named
  per-ABI computations.

**Covered modules** are found by rule, not by list: every
`src/compiler_{lower,backend,regalloc,optimize,liveness,parallel_move,abi,x64}*.tl`.
A module's role follows from its name:

| name | role |
| --- | --- |
| `*_tests.tl` | test |
| `*_linux.tl`, `*_windows.tl` | leaf |
| `compiler_lower*` | lower |
| anything else | shared core |

**Inventory.** Every target token in a covered module must match exactly one
row of [`../scripts/codegen-target-dispatch-inventory.tsv`](../scripts/codegen-target-dispatch-inventory.tsv),
with that row's exact count. A row has these fields: file, scope, boundary,
category, token regex, count and rationale.

- **Boundary:** `policy`, `adapter`, `lower`, `leaf` or `test`. A shared-core
  module admits only `policy`, `adapter` and `test`; a leaf admits `leaf`, a
  lowerer module `lower`, a test module `test`.
- **Category:** `abi`, `runtime`, `target-cfg`, `backend-mode`, `entry`,
  `object-format` or `test-only`. There is no `transitional`.
- **Scope:** a test module may cover itself with one `*` row; every other row
  names its scope.
- **Optimizer:** it has no row at all.

So moving a token, broadening a regex, adding a module to the family or
matching two rows fails the gate. Before adding a policy or adapter row, prefer
naming the fact in the policy or ABI tables. The self-test covers an
unclassified token in shared core and in a leaf, ambiguous rows, a stale count,
illegal categories and boundaries, a new module, an optimizer row, an uncovered
file, and an allowed policy site.

```sh
TYPELISP_BIN=target/stage0/typelisp scripts/check-codegen-target-parity.sh
```

### IR Dumps, Pass Tracing, and Verification

Compiler-development builds expose three opt-in `typelisp compile` diagnostics:

- `--dump-ir` writes the deterministic final textual IR to `-o` (or the
  input's `.ir` path).
- `--dump-ir after-<pass>` writes every function snapshot observed immediately
  after the named optimizer pass. Pass names use the trace spelling, including
  `fold`, `ssa`, `gvn`, `licm`, `global_gvn`, `dce`, and the post-prune
  `total_switch`. A last per-function observation is not necessarily the final
  program: later whole-program or post-prune rewrites must also be inspected.
- `--trace-passes` writes one
  `optimizer-pass|<function>|<pass>|blocks=<n>|instructions=<n>` record per
  observed boundary to stderr.
- `--verify-ir` runs structural final-IR verification and the full SSA
  dominance/use verifier for SSA-shaped functions before any output file is
  written. Failures name the function and, for operand failures, the block and
  instruction index.

`tests/golden/ir_structural_names.tl` imports the compiler AST pool graph,
including nested macro-local type variables. The IR observability gate dumps it
at opt0/1/2 and after SSA. The IR smoke also checks source, macro-local and fresh
syntax IDs in `Var`, `VarArgs` and nested pointer/slice types, plus wrong-owner,
negative and out-of-range identities, including malformed decoded source IDs.
Rendering decodes names through their
structural session; an unresolvable identity prints `<id:N>` instead of indexing
the source intern pool.

The checked-in pass golden is
[`../tests/golden/optimizer_fold.after-fold.ir`](../tests/golden/optimizer_fold.after-fold.ir).
Run the focused cross-platform gate with a current compiler:

```sh
TYPELISP_BIN=target/stage0/typelisp scripts/verify-ir-observability.sh
```

When an intentional IR change updates the golden, generate it with
`compile tests/golden/optimizer_fold.tl --dump-ir after-fold --verify-ir
--opt-level 1`, inspect the diff, and run the focused gate. An unknown pass is
an error and does not create the requested output.

Use [`../scripts/check-backend-target-asm-parity.sh`](../scripts/check-backend-target-asm-parity.sh)
for the next layer down: normalized Linux/Windows assembly parity for selected
user helper bodies. The script compiles a conservative corpus for both targets
at opt levels 0, 1, and 2, strips target-owned wrappers and assembler metadata,
normalizes compiler-generated local labels, and diffs the resulting helper
bodies. It also has a `--self-test` mutation mode that proves the diff gate
fails when a normalized body changes.

```sh
TYPELISP_BIN=target/stage0/typelisp scripts/check-backend-target-asm-parity.sh
TYPELISP_BIN=target/stage0/typelisp scripts/check-backend-target-asm-parity.sh --self-test
```

The corpus intentionally avoids C ABI fixtures, source-level target cfgs, and
runtime-helper-heavy programs. The assembly parity corpus is even narrower: it
compares helper bodies only after function prologues, and deliberately leaves
direct C ABI call setup, indirect-call register differences, shadow space,
sret, stack probing, entry symbols, and runtime shims to the backend smoke and
native integration layers. The normalizer has a narrow target-ABI model for
opt2 scalar-parameter homes: selected incoming scalar argument
registers, plus stack homes forced by target scratch registers, normalize to
`%ABI<n>` pseudo operands for the affected corpus helpers only. Any normalized
helper-body difference is treated as a regression unless the script is
deliberately updated with a tightly scoped, stale-entry-checked expected
mismatch.

### One-shot compile startup profiling

`compile-startup-profile` is a build cfg for attributing one fresh `typelisp
compile` process from the backend-owned process entry through the start of
user-entry loading. The runtime captures `process.entry` before argv or arena
setup. It records raw monotonic ticks in memory and prints them only after the
compile finishes, keeping marker formatting and stderr I/O outside the measured
preamble. The required cross-platform verifier builds an instrumented
compiler, checks marker presence/order, and requires its generated assembly to
match the normal compiler:

```sh
TYPELISP_BIN=target/stage0/typelisp scripts/verify-compile-startup-profile.sh
```

### Selfhost linked-size attribution

Use [`../scripts/analyze-selfhost-build-asm-size.sh`](../scripts/analyze-selfhost-build-asm-size.sh)
for local code-size comparisons of the selfhost compiler. The authoritative
mode reads sized function symbols from the retained unstripped object and
reconciles them with its actual `.text` sections. Current TypeLisp symbols are
attributed to the longest matching checked-in `src/` or `stdlib/` module;
clone helpers, generated specializations, global initializers, and runtime
entry points are reported as separate families. The human report and optional
TSV both record the target, optimization level, producer, source git hash,
function count, object text bytes, attributed function bytes, and the explicit
unattributed remainder. When a final binary is supplied, it also records that
binary's `.text` bytes and the linker delta from the input object.

The stage0 build retains `target/build-stage0/stage4.o` (or `stage4.obj`). Set
`TYPELISP_STAGE0_SIZE_REPORT=1` to analyze that exact object together with the
final stripped publication binary without changing the publication artifact:

```sh
scripts/fetch-stage0.sh
TYPELISP_STAGE0_SIZE_REPORT=1 \
  scripts/build-stage0.sh target/stage0/typelisp target/stage0-branch/typelisp
# human: target/build-stage0/size-attribution.txt
# machine: target/build-stage0/size-attribution.tsv
```

For an opt1/opt2 comparison, retain the benchmark objects and give each report
the exact producer and level:

```sh
scripts/benchmark-compile-cli.sh target/stage0/typelisp
for opt in 1 2; do
  scripts/analyze-selfhost-build-asm-size.sh \
    --asm "target/compile-cli-benchmark/opt$opt/stage2.s" \
    --object "target/compile-cli-benchmark/opt$opt/stage2.o" \
    --binary "target/compile-cli-benchmark/opt$opt/stage2" \
    --target linux-x86_64 --opt-level "$opt" \
    --producer-binary target/compile-cli-benchmark/shared/stage1 \
    --tsv "target/compile-cli-benchmark/opt$opt/size-attribution.tsv"
done
```

On Windows, use the corresponding `.obj` and `.exe` paths from Git Bash;
`llvm-nm`/`llvm-size` or compatible `nm`/`size` tools must support COFF. The
script fails with an actionable diagnostic when sized symbols or `.text`
sections are unavailable. `--asm` alone gives the assembly character report,
and invoking the script without artifacts compiles
`src/main.tl` at opt2. Use `--top N` to change the human table size. The parser
fixtures run in CI, but code size remains a local measurement rather than a
budget gate.

Use [`../scripts/analyze-stage0-size.sh`](../scripts/analyze-stage0-size.sh)
for linked stage0 binary size comparisons. It reports total file bytes, section
raw sizes from `llvm-readobj`, `readelf`, or `objdump`, plus bounded static,
compressed-token, and expanded compiler-owned payload bytes. LZSS totals cover
both the embedded stdlib and the executable-template catalog; TLCH/TLCI totals
are reported separately and depend on the host and generated image inputs:

```sh
scripts/fetch-stage0.sh
scripts/build-stage0.sh target/stage0/typelisp target/stage0-branch/typelisp
scripts/analyze-stage0-size.sh target/stage0-branch/typelisp
```

On Windows, run the shell commands from Git Bash after fetching the Windows
seed (`target/stage0/typelisp.exe`) and use a `.exe` output path. The stage0
publication smoke also prints this report when a section reader is available,
and required PR CI runs it beside the size ratchet on both hosts. It remains
a measurement report rather than a size budget gate. The declaration inventory
must match the binary: analyze a downloaded seed from the source checkout that
built it, or rebuild first as above. A seed with a different declaration set
fails with an explicit expected/found count diagnostic against current sources.

### Instruction counts and LSP latency

The Cachegrind instruction-count harnesses
(`scripts/measure-instruction-counts.sh`,
`scripts/measure-spmd-mode-instruction-counts.sh`) and their baselines are
documented in [`../perf/README.md`](../perf/README.md).

`scripts/measure-lsp-check-latency.sh` is the local interactive LSP latency
harness for repeated `tl/check` requests. It starts one `typelisp lsp` process,
opens generated roughly 500-line and 6000-line documents with a shared stdlib
import, checks invalid syntax, repeats the unchanged check, replaces the text
with valid source, and checks again:

```sh
TYPELISP_BIN=target/stage0/typelisp scripts/measure-lsp-check-latency.sh
```

It writes generated sources and captured LSP
stderr under `target/lsp-check-latency/` by default. Each line reports the
request/response elapsed time for `invalid_check`, `unchanged_check`, and
`edited_check`. The unchanged request demonstrates the per-document result
cache; the final stderr-derived `typecheck-prefix-cache|lsp|...` line reports
the compiler's existing shared-import prefix-cache evidence. The printed
targets are informational local comparison points: under 500 ms for the
roughly 500-line edited check, and under 3 s for the roughly 6000-line edited
check. They deliberately do not fail on wall-clock noise. Use
`TYPELISP_LSP_CHECK_SMALL_LINES`, `TYPELISP_LSP_CHECK_LARGE_LINES`, or
`TYPELISP_LSP_CHECK_WORKDIR` to adjust a local run.

`scripts/measure-lsp-completion-latency.sh` similarly keeps one LSP process
alive while it builds a large persistent workspace index and a deep lexical
scope. It reports cold open/check latency separately from at least 100
alternating lexical/import completion requests, candidate counts, and retained
RSS across the hot loop:

```sh
TYPELISP_BIN=target/stage0/typelisp scripts/measure-lsp-completion-latency.sh
```

The generated workspace is isolated under
`target/lsp-completion-latency/`. Override request, top-level declaration,
scope-depth, or workspace-module counts with
`TYPELISP_LSP_COMPLETION_REQUESTS`, `TYPELISP_LSP_COMPLETION_TOP_LEVEL`,
`TYPELISP_LSP_COMPLETION_DEPTH`, and `TYPELISP_LSP_COMPLETION_MODULES`.
Linux hosts with Valgrind can additionally set
`TYPELISP_LSP_COMPLETION_CACHEGRIND=1` to report deterministic dynamic
instruction counts for the whole cold-plus-hot server workload.

`scripts/measure-lsp-semantic-tokens-latency.sh` opens
`src/compiler_typecheck_core.tl`, records cold open/check plus first full-token
latency, and then verifies at least 100 byte-identical warm full-token
responses from the retained semantic snapshot:

```sh
TYPELISP_BIN=target/stage0/typelisp scripts/measure-lsp-semantic-tokens-latency.sh
```

The row includes source bytes, token and encoded-integer counts, compact result
bytes, cold and warm latency, and RSS deltas for the retained cold snapshot and
the request-local warm loop. Override the request count or source with
`TYPELISP_LSP_SEMANTIC_TOKEN_REQUESTS` and
`TYPELISP_LSP_SEMANTIC_TOKEN_SOURCE`; its scratch files go under
`target/lsp-semantic-tokens-latency/` (`TYPELISP_LSP_SEMANTIC_TOKEN_WORKDIR`).

These three harnesses share `scripts/lib-lsp-client.sh`, a POSIX sh client for
framed stdio JSON-RPC. Its request timers read `date +%s%N` (GNU coreutils,
BusyBox or MSYS2) and stop when the response header arrives. Each timer
includes one `date` spawn, so sub-millisecond requests read as about a
millisecond.

The `compiler-ast-persist-span` inline test in
`src/tests/compiler_ast_types_smoke.tl` checks ownership-only macro copy-out at
empty, singleton and re-span capacity boundaries. It retains distinct views of
shared nodes, destroys the source payload arena, and repeats copy-out while
requiring unchanged node ids, provenance counts/capacities and the span oracle.
Run it at opt0/1/2 alongside the existing span-sidecar and semantic-rewrite tests.

### Allocation profile rows

`compile --profile-allocations` emits opt-in arena ownership rows for any input
program. Rows report the phase, owner, arena root, bump-position bytes,
committed bytes, reserved bytes, and segment count. Arena roots make overlapping `active` and
named-owner rows explicit so consumers can de-duplicate them. Without the flag,
the compiler emits no rows and keeps the allocator fast path unchanged.
`bump_bytes` includes the retained high-water position of rewound overflow
segments; use `committed_bytes` when reconciling the rows with OS commitment.
In the `typecheck.macro.peak` snapshot, `macro-enclosing`, `macro-scratch`,
`macro-symbols-current`, `macro-symbols-retired`, `macro-symbols-reclaiming`,
`macro-hygiene-cache`, the `typecheck-*` scratch/cache owners, `source-pools`,
`intern-persistent`, and the process-lifetime `compiler-entry` arena identify
the independently owned arenas that are simultaneously live. Repeated
snapshots capture transient symbol-generation overlap without treating retired
roots as concurrent indefinitely.

The ordinary phase snapshots also name the state surface, IR-label,
load-provenance, lexer-token-buffer, reader-node-pool, and aggregate-layout
owners. The backend snapshot adds `backend-output-home`, the retained streaming
assembly owner. Batch mode names the exact saved entry scratch head at
`batch-pre-release` and `batch-post-release`, then emits `batch-steady` only
after that owner is destroyed. Together these rows distinguish intended session
roots from lower-phase storage that accidentally survives an entry.

The optimizer emits four owners that it reads just before releasing them.
`optimizer-scratch` is the per-function escape scratch and `optimizer-late-scratch`
is the same pattern for the fused post-prune late passes; both are already
rewound to zero when they are read, so they stay on the `optimize` phase.
`optimize-inline` is the whole-program inline stage's arena and `optimizer-input`
names the arenas the per-function loop reads its input from: the slot-range
chunks the stage places each caller's final body in, and the carrier that holds
the loop's sequence and any survivor copied there. All of them are read at their
high-water mark, so they carry the shared `optimize.inline` phase: the arenas
they name are already destroyed by the time the `optimize` snapshot runs, and
folding them into that snapshot's unique-root sum would report storage the phase
boundary no longer holds. The late scratch and the input arenas are only created
at `--opt-level 2` -- the level whose inline stage is the full census/SCC
pipeline, and where the late passes run. So `--opt-level 2` emits one
`optimizer-input` row for each chunk no survivor is in, then the
`optimize-inline` row (released before the per-function loop, once every
survivor is resident in its chunk), then one `optimizer-input` row for each
remaining chunk as the loop passes its last survivor, and the carrier's
`optimizer-input` row last (released after the loop). The sum of the
`optimizer-input` rows is the input's total size. At `--opt-level 1` the loop
reads the inline arena directly and only the `optimize-inline` row is emitted,
after the loop.

### LSP transcripts

`lsp-frame-run-transcript` is the TypeLisp-only in-process framing adapter for
tests that need exact stdin bytes plus exact captured stdout, stderr, and exit
status. It runs the production frame parser and request handlers in a
destroyable session arena, keeps transport buffers in a separate destroyable
arena so nested tool scratch scopes cannot own captured output, copies the
result to the caller arena, and performs the fresh-session reset before either
arena is destroyed. `src/tests/lsp_frame_smoke.tl` covers EOF/error framing,
ordered messages, message-owned JSON-RPC ids, and document/compiler cache A/B
isolation. Public transcript-corpus discovery and process-count measurement
remain owned by the public-tool verifier rather than this substrate.

`tests/public-tools/run-corpus.sh lsp fresh` retains the original
one-process-per-fixture LSP oracle. `lsp batch` materializes a versioned,
tab-separated manifest whose rows name one case ID, exact raw/framed input,
and separate stdout, stderr, and status files, then runs every logical session
serially through one `typelisp lsp --transcript-batch` process. The TypeLisp
runner validates the complete manifest before executing it, resets state on
both sides of every session, and destroys the session and transport arenas.
Linux defaults to `lsp differential`: all fresh processes plus one batch
process, followed by normalized per-case byte/status comparison before the
existing fixture specs. Windows defaults to `lsp batch`. Use
`scripts/verify-lsp-transcript-batch.sh` for the fast manifest/parser mutation
coverage, including raw malformed-frame input and incomplete result sets.

### Stage0 and the bootstrap

The stage0 workflow, the minimum-seed policy, the published assets and the
Windows toolchain are described in
[`../docs/testing-and-bootstrap.md`](../docs/testing-and-bootstrap.md#self-hosting-and-bootstrap).
The published toolchain is the single `src/main.tl` binary: every command is
reached through its dispatcher, and each command's logic lives in a main-less
`*_cli_core.tl` module that `main.tl` imports. `tests/cli/selfhost-surface.cases`
pins the `--help` command list next to one smoke case per command.

`scripts/fetch-stage0.sh <stage0-tag>` pins an immutable `stage0-*` release
instead of `stage0-latest`. The script downloads the host platform asset,
verifies the file is non-empty, checks `SHA256SUMS` when the release provides
it, and installs the command under `target/stage0/`. It uses release asset URLs
instead of fetching git tags, so the mutable `stage0-latest` tag cannot be
stale or clobber a local tag.

The checkout root also has a `typelisp.pkg` whose binary entry is
`src/main.tl`, so `typelisp build` from the repository root builds the
selfhost CLI package into `target/release/`. That package build refreshes the
compiler identity from the checkout's exact Git HEAD before compiling. The CLI
smoke in `tests/cli/selfhost-build-run.cases` poisons the old identity stamp,
checks that the root-built compiler reports the refreshed identity, and uses it
for downstream binary and static-library package builds. The stage0 workflow
keeps using the direct `compile src/main.tl` path plus native linking so a seed
compiler can build its successor without depending on its own `build` command.

`scripts/ci-verify.sh` is the complete local verification gate. With
`TYPELISP_BIN` unset it fetches `stage0-latest` as the seed, which performs the
single compiler build of the flow: the stage1->stage2->stage3 bootstrap
fixpoint of `scripts/check-bootstrap-fixpoint.sh` over `src/main.tl`. Every
remaining gate runs on that branch-built stage2 compiler after a fail-closed
probe confirms it can compile, assemble, link, and run a native program on the
host. `--jobs N --memory-mib MIB` runs up to N gates at once, as hosted CI does
with `--jobs 4 --memory-mib 14336`, within MIB of the gates' measured memory
reservations. The largest single gate, the CLI smoke's root package build,
peaks near 8 GiB. Standalone `verify-*`/`check-*` runs also fetch the published
stage0 when `TYPELISP_BIN` is unset; CI always passes it explicitly. The gate table and
the rules for adding a gate are in
[`../scripts/README.md`](../scripts/README.md#what-is-a-ci-gate).

`scripts/check-bootstrap-fixpoint.sh` is host-sensitive. Linux uses the `as`
plus `ld` path and compares `stage2.s` with `stage3.s` (building stage4 only
when they differ). Git Bash/MSYS/Cygwin on Windows emits `windows-x86_64`
assembly, assembles each stage with `clang --target=x86_64-pc-windows-msvc -c`,
links `stage1.exe` and `stage2.exe` with MSVC `link.exe`, runs both generated
compilers, and compares the Windows `stage2.s` and `stage3.s` outputs. Run it
from Git Bash:

```sh
scripts/fetch-stage0.sh
scripts/check-bootstrap-fixpoint.sh target/stage0/typelisp.exe
```

or fetch from PowerShell and invoke the shell script through `bash`:

```powershell
powershell -ep Bypass -f scripts\fetch-stage0.ps1
bash scripts/check-bootstrap-fixpoint.sh target/stage0/typelisp.exe
```

The Windows native-link gate also requires `llvm-ar` and verifies deterministic
package `.lib` output through both compiler tool discovery and an explicit
`TYPELISP_WINDOWS_LIB=llvm-ar` override. That override accepts only MSVC
`lib[.exe]` and `llvm-ar[.exe]` executable basenames so the compiler can select
the documented reproducible argument contract.

The bootstrap's embedded-stdlib smoke runs the generated compiler from a
scratch directory without a colocated `stdlib/`, then checks that
`TYPELISP_STDLIB_ROOT` still overrides the embedded contents. Before each
self-host generation after stage1, the preceding compiler builds the exact
embedded source manifest into ordinary `stdlib.tlci` bytes, then
deterministically wraps those bytes in the compiler-owned TLCH deployment
envelope. The generated compiler expands the envelope before the existing
parser and production W^X loader, and the bootstrap smoke requires
`typelisp inspect embedded:stdlib.tlci` to register every current macro
identity. Trusted embedded-stdlib native routing is the default on both hosts;
the bootstrap embedded-provenance parity compile proves the staged disk-source
and embedded-source paths converge.

### Embedded stdlib and TLCI gates

`src/compiler_embedded_stdlib_payload.tl` is the canonical explicit build-input
list. Editing a listed stdlib source changes the next compiler build directly;
there is no generated source to refresh. Run
`scripts/verify-embedded-stdlib-payload.sh` to check declaration completeness,
deterministic output, one-byte source mutation propagation, and byte-for-byte
decoding with a branch-built compiler.

CI's isolated TLCI mutation bootstrap enables the deterministic same-commit
mutation witness. It starts from the same published stage0 seed as the main
bootstrap and runs beside it rather than after it. It copies `src/` and
`stdlib/` below that bootstrap's target workdir, changes only the zero-body
sentinel in the already-native `stdlib.core_macros/when` transformer, and
builds every generation from that tree. Stage1 must emit exact package-qualified source-route evidence and the
changed diagnostic. Stage2, with the newly produced image embedded, must emit
the matching native-route evidence with no contradictory source record and the
same changed diagnostic. Stage1, stage2, and the final converged producer must
then emit byte-identical ordinary images, TLCH envelopes, source hashes, and
inspected producer provenance; the ordinary assembly and embedded-provenance
fixpoints remain mandatory. The fast adaptive-control test rejects wrong or
duplicate routes, stale identities, and unequal payload artifacts before the
expensive bootstrap begins. Checked-in sources are never edited by this gate.

The `verify-embedded-stdlib-tlci.sh` gate separately checks ordinary-image and
envelope byte determinism and exact envelope expansion, proves that a
source-only mutation changes the image, ratchets source-lowered native-entry
coverage, and stress-tests the mapped host callback/session bridge on both
hosts. Unsupported transformer shapes remain explicit registration shells and
fall back to interpreted CTFE. The same gate derives the exact
identity/arity/variadic/result-kind census from the parsed producer inputs and
compares it with `tools/embedded-stdlib-tlci/identity-fixtures.tsv`; additions,
removals, duplicates, or declaration-shape changes therefore require an
explicit fixture review.

`verify-stdlib-tlci-identity-differential.sh`, invoked by the required
compile-profile gate, compiles the fixture manifest's witnesses through the
default trusted route, a byte-identical explicit root, and a comment-modified
source root. It requires every identity in its assigned witness on all three
routes, every native identity and result kind and every source control, zero
catalog fallback/miss/load-failure counters, zero native hits in the source
control, byte-identical assembly for every `Expr`, `Module`, and `Decls`
witness, and authored-error diagnostic parity. The enclosing gate's direct
embedded verifier and comptime-host smoke pin malformed requests/handles,
fuel exhaustion, native abort, and no partial result commit.
`verify-compile-profile.sh` compares mapped-image and explicit-source assembly;
its native-result counters require real `Module` and `Decls` results to commit
through the existing module/declaration validation and splice paths.

The production-route stress gate (`verify-tlci-native-route-stress.sh`)
crosses pool-reset and image release/remap cycles with more than 25,000 routed
calls per host. Its 16,000-call heavy row uses the native `__tl-project-field`
Expr identity: its expanded reads are pure and removed by ordinary
optimization, while every call still crosses the production macro walk and
mapped catalog entry. Small required probes retain `__tl-box-place`, `and`,
`or`, `unless`, `hash`, `owned`, and `append!` coverage. The gate parses
compile-profile detail rows per batch entry and requires exact
identity/arity/call counts; built-in controls prove missing, duplicate,
wrong-arity, and wrong-count rows fail closed.
`target/tlci-native-route-stress/<host>/evidence.tsv` records native and source
compile time, assembly comparison and diagnostic-control time, generated-source
and native/source assembly bytes, and native/source main-backend time for all
rows plus aggregates; `reproduce.txt` records the exact working directories and
commands for the two successful routes. With `TYPELISP_CI_TIMING` set it also
appends `native-compile`/`source-compile` rows with their real process statuses
and `native-main-backend`/`source-main-backend` aggregates.

The required `check-tlci-native-route-size.sh` consumer compares row 0's
native assembly with the reviewed host baselines in
`scripts/tlci-native-route-size-policy.tsv`, whose rows name the dispatch
denominator, the causal change and the hosted evidence. The checker reports raw
and normalized bytes and fails on a missing/duplicate metric, a host-specific
breach, more than 15% policy headroom, or a policy change without an issue/PR
and evidence link. Reproduce both evidence and the ratchet with:

```sh
scripts/verify-tlci-native-route-stress.sh \
  target/compile-profile-verify/typelisp-compile-profile
scripts/check-tlci-native-route-size.sh \
  target/tlci-native-route-stress/<host>/evidence.tsv
```

The required `stage0-size-ratchet` gate holds #6260's published-stage0 target.
It measures the converged bootstrap compiler, which comes from the same compile
and native-link route as the published stage0 (a stripped copy on Linux, the
linked executable on Windows), against the host's ceiling in
`scripts/stage0-size-policy.tsv`. That file is an append-only ledger per host:
the last row is the ceiling, an ordinary `ceiling` row may only lower it, only
a `raise` row naming its authorizing change may raise it, and no ceiling may
sit below the 10,000,000-byte target. When a change shrinks the binary well
under its ceiling the checker prints the lower value to append. Reproduce with:

```sh
scripts/check-stage0-size.sh target/bootstrap-fixpoint/stage3 linux
```

The TLCI stress gate also checks the ordered intern storage schema on a source compile and
requires two complete copies in the two-entry batch route. It pins equal source
record/map occupancy, fixed capacities, zero resize observations, non-zero
reserved payload bytes, and bounded total/maximum probe accounting. The inline
`compiler-driver-profile-intern-storage-job-isolation` test owns the A/B
reset/interleaving proof for equal numeric IDs in distinct profile owners.

Package dependency images also carry relocatable checked frontend surfaces.
`verify-package-surface-tlci.sh` builds one executable with three directly
declared dependency-free libraries, colliding local names, aliases, repeated
imports and generated keys, a generic macro, ordered `Module` and `Decls`
results, a registration shell, and dependency SPMD metadata. The trusted
consumer maps exactly three code catalogs and pins its catalog-hit,
native-dispatch and per-kind result counts; package-qualified rows pin two
calls to the shared-base macro, the left/right defining identities, and
repeated generated/shell calls. All three surface fragments hydrate
transactionally into consumer-owned AST/fact/SPMD storage. The forced-source
twin maps zero code, records zero hits and native dispatches plus one
interpreted fallback per catalog hit, and produces byte-identical assembly and
identical runtime exit/stdout/stderr. Authored-error and host-fuel failure
twins retain equal semantic text and expansion attribution. The
injected-last-fragment control remains all-or-source: a consumer never mixes a
partially hydrated dependency prefix with parsed dependency source.

The separately invokable `verify-embedded-stdlib-tlci-resources.sh` gate runs
the production image builder, matched opt1/opt2 self-builds, cold startup, and
a native/forced-source expansion pair under an 8192 MiB complete-process-tree
ceiling on Linux and Windows. The expansion assemblies must be byte-identical,
and profile counters must prove non-vacuous native and source routes. Its
`report.tsv` holds informational host measurements (peak memory, wall time,
sizes, Cachegrind evidence where available); `assertions.tsv` keeps the
required correctness/cap results separate. Reproduce the full report with a
current compiler:

```sh
TYPELISP_BIN=target/bootstrap-fixpoint/stage2 \
  scripts/verify-embedded-stdlib-tlci-resources.sh
```

### Runtime-gap markers

The gate runs every check with a freshly bootstrapped stage2 compiler, so
source-only selfhost changes always run: there is no "skip until the published
stage0 catches up" mechanism, and a test that fails to build fails the gate.

For a stdlib runnable fixture with a narrowed runtime-only blocker, use
`requires-runtime-gap:<host>:#NNNN:<stderr-substring>` as the sixth
`scripts/verify-stdlib.sh` manifest field, where `<host>` is `linux`,
`windows`, or `all`. That marker skips only on the named host when the row
builds, exits with the wrong status, and stderr contains the tracked substring.
If the row starts passing on that host, the verifier reports that the marker
should be removed.

### Native integration tests

`ubound_entry_location.tl` exercises the existing multi-block unsigned-bound
rewrite at opt0/1/2 on both hosts. Its manifest rows pin first-trip and mid-loop
bounds diagnostics, a negative cursor, skipped loops, and check-before-division
trap ordering. The optimizer span tests also exercise the actual entry-copy
producer, collision suffixes and function ownership.

`ubound_self_loop_call.tl` keeps a clean scalar callee out of line with tail
conversion, so its rotated body is both header and latch. Its manifest rows
exercise opt0/1/2 trap parity, negative backedges and check-before-call ordering.

`scripts/verify-integration.sh` contains the heavier native checks that build
and run TypeLisp programs as native executables. Linux uses the explicit
`compile -> as -> ld` path; Windows Git Bash/MSYS/Cygwin uses
`compile --target windows-x86_64`, `clang`, `lld-link`, and a small PowerShell
runner to preserve native Windows exit codes. Use this layer for behavior that
only shows up after execution: exit status, stdout/stderr, diagnostic rendering,
deterministic file output, and import-aware driver behavior.

Every case run has a 300 s wall-clock deadline
(`INTEGRATION_CASE_TIMEOUT_SECONDS`). On Linux, GNU `timeout` kills the case's
whole process group; on Windows, the queue runner kills the case's process
tree with `taskkill /T`. A case past its deadline fails its own row as
`FAIL: <case> (timeout after 300 s)` with the output it wrote. The remaining
cases still run, and nothing is skipped or retried.

The integration manifest `tests/integration/native.manifest` serves both hosts:
each row names the hosts it runs on and the opt levels it runs at (the default
level and/or explicit `--opt-level` pins), and
`scripts/expand-integration-manifest.awk` expands one host's rows. When a
program or smoke driver needs another imported module, add the dependency to
the owning manifest row so the CI runner exercises the same import graph
reviewers see locally. The same script also owns host-specific
backend/compiler-driver fixture checks that are too low-level for a manifest
row.

Native compilation batches rows separately by their stdlib layout and exact
optimization choice. Default-level rows retain default argv; a pinned level 1
is a separate group with explicit `--opt-level 1`. The bounded pool, failed-chunk
standalone replay and Windows COFF/forced-assembly checks apply to every group.
Linux compares a batch output with a standalone compile in each nonempty group.
`--self-test-batch-observability` also checks mixed levels, empty groups, chunk
boundaries, exact target/stdlib flags and invalid level metadata. Setting
`TYPELISP_INTEGRATION_BATCH_SIZE=0` retains standalone compilation for all rows.

The `c_function_pointer_flow` row uses a native C provider from
`benchmarks/c_function_pointer_flow/baseline.c` to exercise typed code addresses
through a higher-order resolver, globals, an imported relay, struct and enum
fields, and an escaping closure. It checks the provider's resolver counter to
catch repeated evaluation and passes a pointer-containing struct back to C.
The `c_function_pointer_publication` row uses a writer thread to fill a pointer
table and publish a sequentially consistent ready flag. The reader calls through
assigned and branch-selected entries after acquiring ready and before joining the
writer; no atomic pointer loads or integer callable casts are used.
The `c_function_pointer_null` row requires exit 134, empty stdout and the exact
null diagnostic even when the checked result is unused. These rows run on both
hosts; assembly generation alone does not replace their native execution
checks.

Generated import regressions must exercise both `Module` and `Decls` output.
An import has namespace effects even without a visible declaration name; the
canonical generated wrapper must preserve the metadata that causes the macro
walk to load it. The `decls_generated_imports` and
`decls_generated_import_nested` native rows cover aliases, empty dependencies,
repeated generation, selected/wildcard imports, selected items emitted by an
imported declaration macro, target conditionals and nested macro imports.
`generated_import_alias_scopes` retains same-alias repetition and independent
module scopes. The structured call-site smoke loads an imported
provider whose quote line differs from the caller line, checking missing
imports, alias conflicts, and missing selected items from newly loaded and
already loaded modules. Wildcard/selected collision controls reject unused
bindings, while repeated selections remain idempotent. The missing and conflicting
import controls in the safety corpus must fail even when no
generated binding is used. Run affected fixtures at opt0/1/2; an unused missing
import that compiles successfully is not evidence of valid expansion.

Source selected imports of generated exports are the mirror case. The
public-check `loader-selected-*` cases pin E0304 and the selected import's own
span for both import orders, used and unused missing selections, source and
package checking, and compilation. A cross-file case keeps pending generator
exports valid while reporting a different missing item. Valid source, package
and embedded-stdlib selections remain accepted, and the lazy loader smoke
requires a selected item to materialize a provider after a summary-only import.
The `source_selected_generated_export` native row selects values, a function, a
struct, an enum and its constructors that exist only after the provider's
module-scope generators have run, through a direct generator, an imported
declaration macro with operands, nested generation, a target-conditional
generator, a repeated selection, and a qualified import of the same module
placed after the selections. The `source_selected_generated_*` safety rows keep
the rejections: a missing item from a generating module fails although unused,
an already loaded generating module does not suppress that (the span row pins
the import's own line), and `source_selected_plain_missing_reject` pins the
unchanged load-time failure for a module without generators. The loader
self-test loads a generating provider through both the source and the package
walker. Deferring without the completed-expansion check would accept missing
items, so keep both halves together.

For Windows import-only regressions that fail before a native executable is
linked, use the published stage0 directly from PowerShell:

```powershell
target\stage0\typelisp.exe check src\compiler_backend_tests.tl --stdlib-root stdlib --stdlib-root src
target\stage0\typelisp.exe run src\tests\compiler_parse_smoke.tl --stdlib-root stdlib --stdlib-root src
```

### Codegen and CLI case files

`tests/codegen/*.cases` hold the table-driven compile/run/assembly-shape
checks, run by `scripts/verify-codegen-cases.sh` (the format is documented in
its header). A case names a source, the targets, opt levels and backend modes
it runs under, and an action (compile, build, link and run, `typelisp run` or
`check`); its rows then assert on the exit status, stdout/stderr, the whole
assembly or one function body: fixed text, regular expressions, match counts,
and named analyzers from `scripts/codegen-cases-analyzers.awk` for shapes a
grep cannot express (backward branches, prologue pushes, unrolled groups).
Everything is evaluated with sh/grep/awk, never with the compiler under test.
Each CI gate runs one file, or one case of it with `--only`; every file's
header names its gate.

The `static-array-reachability` row in `asm-shape.cases` checks omission of
imported unused 0-, 1-, 8- and 128-element static arrays at opt0/1/2 for both
targets.
The same native integration fixture verifies exact element bits, mutation,
borrowed writes and independent storage. `static-array-opt0-retained-roots`
checks retained function bodies, global aliases, runtime initializers, opaque
call arguments and conservative retention without `main` at the IR boundary.

Use this layer when a native integration fixture can still return the right
exit code while silently falling back to slow codegen: `asm-shape.cases` pins
the opt2 regalloc/backend/optimizer shapes of the integration fixtures,
`crypto-sha.cases` the hash cores' wipe loops, `by-value-aggregate-abi.cases`
the internal aggregate ABI, `math.cases` freestanding stdlib math, and
`ispc.cases` the ISPC comparison corpus contracts.

The same runner executes the CLI transcripts in `tests/cli/*.cases` (run and
exec steps, file fixtures, stdout/stderr rows) for the public-tool, selfhost
build/run and host-action gates, and the SPMD case files in `tests/spmd/`. The
case files are the command inventory: `selfhost-surface.cases` requires a smoke
case for every command that `--help` lists. Add public command, package, docs,
LSP, REPL, formatter, or platform cases to the matching `tests/cli/` file.

### Selfhost native generated programs

`scripts/verify-native-link-linux.sh` covers Linux-only cases where the selfhost
compiler emits assembly that must then assemble, link, and run as a native
executable. It builds `src/main.tl` with the compiler under test and runs
`tests/codegen/native-link.cases` with that driver as the compiler: generated
file-to-file assembly for multi-file and package imports, stdlib imports,
runtime helpers, dynamic arrays, traps, and stack-argument call shape, plus the
direct-object (no-assembler) ELF link path via `build --direct`.

`scripts/verify-fs-rooted-linux.sh` owns the private rooted exclusive-create
filesystem boundary. It runs retained-descriptor rename, final-component and
child symlink refusal, deterministic mkdir/reacquire substitution, competing
`O_EXCL` writers, short-write/EINTR/cancellation and stage-specific failure
injection, exact close-attempt accounting, mode/content checks, and the
direct-object-enabled semantic-fallback planner. It also exercises a real
`RESOLVE_NO_XDEV` bind-mount race when the runner has mount permission and
prints an explicit limitation when it does not.

This runner is intentionally separate from the plain integration manifest:
manifest rows cover source programs built by the public compiler, while this
script covers generated-program behavior where the generated `.s` is the test
artifact.

`scripts/verify-process-runtime-linux.sh` builds and runs two modes of
`tests/integration/process_runtime_linux_failures.tl` through the assembly
fallback. The fault mode enables `process-linux-test-hooks`, reducing registry
capacity to four. It holds four child capabilities, verifies exhaustion returns
the typed spawn error before any process syscall, and checks slot reuse and
cleanup. Four threads also reserve all slots concurrently, reject cloned
authority, and release and reuse the reservations. Existing syscall faults,
reverse waits and stale capability checks remain in the same mode. The
`process-child-concurrency-test` mode does not enable fault hooks: their
counters are deliberately single-threaded. Four threads each perform 32 failed
execs and 32 successful starts/waits against the native runtime. The final
check requires unchanged descriptor count and no remaining children. Both modes
must exit 42 with the exact metrics line and empty stderr; a compiler or
runtime failure in either fails the gate.

### Stdlib documentation gate

`scripts/verify-stdlib-docs.sh` (Linux-only) discovers every stdlib module
outside `stdlib/tests/`, requires module and item documentation comments,
generates Markdown through `typelisp doc`, and runs `typelisp doc --test` with
`--stdlib-root`.

### Repository doctest gate

`scripts/verify-doc-tests.sh` discovers documented `.tl` files under
`stdlib/`, `src/`, `examples/`, `tests/`, and `docs/` by scanning for public
canonical `;#`/`;:` doc comments or TypeLisp fenced examples, then runs
one `typelisp doc --test --batch <listfile>` process with `--stdlib-root`.
This gate does not use a hand-maintained file manifest, so adding documented
TypeLisp source with fenced examples automatically adds doctest coverage. The
gate requires at least one runnable doctest file, and runnable doctests execute
on both Linux and Windows. Markdown files are not doctested: SPEC.md's
metadata-bearing examples run through `scripts/verify-public-tools.sh`.

### Repository inline-test gate

`scripts/verify-inline-tests.sh` discovers `.tl` files with top-level
`(test ...)` items under `src/`, `stdlib/`, `tests/integration/`,
`tools/`, `tests/inline/`, and `examples/`, in sorted order. It runs them as
contiguous chunks of up to 12 sources, each one `typelisp test --batch`
process, in the bounded pool of `scripts/lib-bounded-pool.sh`:
`TYPELISP_INLINE_TEST_WORKERS` chunks at once (1-3, default 2), each under an
enforced 6144 MiB cap and an 1800 s timeout (a user cgroup on Linux, a Job
Object on Windows). Every source keeps its own scratch arena and a full driver
reset (#4820), so chunking changes only the number of processes. The gate
requires, over the chunks' output in queue order, one count line and one
passing summary per discovered source in discovered order and no source with
zero tests, plus each chunk's own batch aggregate; a chunk that fails, leaves
no status or memory report, or is stopped by its cap or timeout fails the gate
with its streams. On Linux a focused `src/compiler_profile_summary.tl` run under
a 1 GiB cap comes first (#5122). `--self-test-chunks` runs only the chunk
accounting self-test that every run also performs first. This gate is separate
from doctests, manifest corpora, and smoke drivers so source-owned checks can
be added next to the declarations they exercise. Chunks share the checkout, so
inline tests must keep writing uniquely named paths (under `target/` or the
ignored `tests/scratch/`).

### Documentation site

The site builder and its local command are described in
[`../docs/testing-and-bootstrap.md`](../docs/testing-and-bootstrap.md#documentation-site).
The smoke driver `tools/doc-site/doc_site_smoke.tl` checks the navigation
links, generated page anchors, CSS asset marker, duplicate output detection,
manifest count guard, and HTML escaping behavior without depending on
file-system writes. `scripts/verify-doc-site.sh` (gate
`stage2-docs-pages-build-path`) builds the site into `target/doc-site-verify/`,
with native builder logs and objects in `target/doc-site-verify-work/`, asserts
`doc_site_smoke.tl` passes (exit 42), and fails on a build error, a missing
required page, a dead local link, or an unresolved anchor. On Linux its RSS
guard needs GNU `time -v`; set `DOC_SITE_TIME_BIN` when that is not
`/usr/bin/time`. Set `DOC_SITE_OUT` to choose a publish-ready output
directory; `.github/workflows/docs-pages.yml` runs the same verifier before it
publishes.

### CI expectations

Pull requests get Linux and Windows coverage from `scripts/ci-verify.sh`
(wired in [`../.github/workflows/ci.yml`](../.github/workflows/ci.yml)). Each
host bootstraps the full `src/main.tl` CLI as described under
[Stage0 and the bootstrap](#stage0-and-the-bootstrap); all downstream gates
receive the converged compiler, and the previous bootstrap generation is
retained for the cross-mode differential. The separate TLCI mutation bootstrap
keeps its independent build from the same seed. Other producers hand their compilers and
references to later gates through path files under `target/` (see
`scripts/README.md`). Both hosts must run every applicable gate. Linux-only
obligations include build invariance, instruction counts and Linux runtime
boundaries; Windows executes its native link/run gates. A missing compiler
capability or required tool fails verification, rather than selecting a
fallback that silently omits required coverage.

CI sets `TYPELISP_CI_TIMING=1` for that serial verification flow. Each host
uploads one compact `ci-timing-<host>` TSV artifact with columns `gate`,
`case_or_chunk`, `phase`, `elapsed_ms`, `exit`, and `host`; the job log prints
only aggregate phase totals and the slowest rows. Detailed rows cover gate
totals plus integration stage/compile/assemble/link/run/assert phases,
build-invariance compiles, lint and selfhost-manifest chunks, inline-test batch
and per-file work, and CLI helper cases. The native
`compiler_frontend_smoke_suite` also appends one row for each isolated child,
each semantic-index aggregate component, and the nominal fixture's build,
selection, assertion, and release phases. The parent records every child's real
exit status after capture, while the child writes directly to the inherited
artifact so semantic stdout/stderr stay empty. The integration runner rejects
missing or duplicate frontend-smoke rows. Timestamps come from a monotonic
clock, and labels never include command lines, absolute credentials, or source
text. Local runs remain uninstrumented unless the same environment variable is
set. A successful flow ends with exactly one
`CI verification / all / complete-verification` row measured from timing
initialization through the last required gate; duplicate writes fail closed.
The artifacts are evidence for performance work; no wall-clock budget or trend
check reads them in CI.

### Build invariance

The Linux build-invariance gate (`scripts/check-build-invariance.sh`) compares
the assembly that an opt1-built and an opt2-built compiler emit for the same
corpus. Within each chunk, identical compile-input paths at the same
optimization level share one fresh output from that chunk's compiler. The
original logical case records still drive every opt1-built/opt2-built byte
comparison. The complete chunk inventory must match the corpus, including
multiplicity, so a duplicated chunk cannot replace a missing one. The plan is
reconstructed and checked before invocation; existing outputs fail rather than
acting as cache hits. Alias copies require a nonempty regular canonical output
and exact byte equality. Source-set and compiler digests must remain unchanged
through the gate. Reuse never crosses chunks or compiler identities, and all
four independently timed selfhost compiles and both compilers' standalone
sentinels remain mandatory. The 64-entry limit counts logical cases, including
aliases. Run `scripts/verify-build-invariance-batch.sh` for the planner,
boundary, ownership and fresh-output failure checks.

The gate reuses its freshly built opt1 compiler for two complete opt2 memory
workloads: the singleton batch compilation of
`compiler_codegen_smoke_suite.tl` and a standalone build of the backend test
driver `tests/compiler_backend_smoke.tl`, whose `main` reaches every
`compiler_backend_tests.tl` test. The codegen assembly still participates in the
ordinary byte comparison; it is not compiled again just to measure memory. Its
report name belongs to that one invocation: a report that already exists fails
the compile, and the gate fails without both complete-fixture reports. These
jobs require the `systemd-user-cgroup` backend of `scripts/run-memory-bounded.sh`
with swap disabled, and fail if enforcement, compilation, or the
machine-readable report is unavailable; the wrapper's RSS fallback cannot
satisfy this regression. Linux CI starts the runner's user manager and verifies
this backend before running the gates. Reports and command logs are retained in
`target/build-invariance/backend-memory/` and uploaded by Linux CI; large
assembly/executable outputs remain local.

Every chunk of both producers, including the four selfhost compiles, and
backend-tests are jobs of the existing bounded worker pool
(`TYPELISP_BUILD_INVARIANCE_WORKERS`, 1-3, default 2; 1 executes one job at a
time). Large compiler smoke inputs stay isolated from other unique inputs;
consecutive logical cases naming the same actual input at the same requested
optimization share one fresh compile through the ordinary alias plan. All
logical cases still count toward the 64-case ceiling, produce their named
assembly, and receive their own byte comparison. Integration case names retain
their manifest spelling; the build-invariance corpus requests opt2 for them,
while its two selfhost rows request opt1 and opt2.

Each job runs through `scripts/run-memory-bounded.sh` with swap disabled:
8192 MiB for the backend-tests build, both producers' complete
codegen smoke and all four selfhost compiles, and 4096 MiB for every other
chunk. Selfhost compiles have a 1200 s timeout; every other job retains its
600 s timeout. Before joining the pool, selfhost compiles had no per-job
timeout and were bounded only by the workflow deadline. A job starts only
while the caps of all running jobs fit 12288 MiB,
so no two 8 GiB jobs overlap; a job whose cap does not fit waits while later
jobs that fit run. The existing outer CI scheduler still owns the complete
verification graph. Chunk metrics and the chunk log lines carry every chunk's
peak. Locally, use one worker for the shared 8 GiB test allowance; the hosted
two-worker resource topology is separate from that local allowance.

Linux CI retains the authoritative corpus, both producers' complete case,
entry and alias plans, queue records, chunk metrics and `provenance.txt` in
its existing `backend-memory-Linux` artifact. The provenance records source
and compiler identities and the common target, cfgs, backend and ordered roots,
so a coverage audit can interpret every requested optimization and comparison
from the same records the local gate executes.

The gate compares a chunk as soon as both producers have emitted it. It passes
only with exactly one successful result per queued job: a failed, missing or
foreign result, a job left running, an aborted pool and a worker that exits
without reporting all fail. After any failure the running jobs finish, no
further job starts, and the rows that did run are still published. Jobs write
private timing and metric rows that the gate merges in queue order, so the
published rows do not depend on scheduling. The same script covers the queue,
budget, exactly-once, failed-job, killed-worker and caller-abort cases with
real concurrent workers. CI runs these helper checks on Linux only, like the
gate they serve: the negative cases need real symbolic links, which Git Bash on
the Windows runner cannot create.

### Lint gate and the local loop

`scripts/check-tl-lint.sh` checks each selected tracked TypeLisp source unit
once, in batches of at most 32 files by default, and fails CI on any finding.
Batches split at `src/` boundaries: all files receive the normal, redundant-name
and supported name-case rules; only tracked compiler/tooling sources receive
`--deprecated-string-concat` and `--redundant-begin` in that same invocation. The concat rejection
probe remains independent. `TYPELISP_LINT_BATCH_SIZE` must be a positive integer.
Plain `typelisp lint <file.tl>` remains warn-only for reviewable cleanup slices.

The package-lock CLI fixtures in `tests/cli/selfhost-build-run.cases` wait for
exact staging/commit observations through `scripts/lib-package-lock-test-wait.sh`
with a 60-second bound, rechecking the file predicate after a writer terminates
to avoid a publication/exit race. Readiness does not replace the final child
exit-status, lock-content, conflict-diagnostic or stage-cleanup assertions.
Premature exit and timeout print the captured child logs; a staging-directory
observation error fails immediately with those same diagnostics.

For a selfhost compiler change, a typical local check (after
`scripts/fetch-stage0.sh`, with `tl=target/stage0/typelisp[.exe]`) is:

```sh
$tl fmt --check src/<changed>.tl
TYPELISP_BIN=$tl ./scripts/verify-selfhost-compile-manifest.sh
TYPELISP_BIN=$tl ./scripts/check-tl-format.sh
TYPELISP_BIN=$tl ./scripts/check-tl-lint.sh
TYPELISP_BIN=$tl ./scripts/verify-public-tools.sh
TYPELISP_BIN=$tl ./scripts/verify-stdlib-docs.sh
TYPELISP_BIN=$tl ./scripts/verify-doc-tests.sh
TYPELISP_BIN=$tl ./scripts/verify-inline-tests.sh
TYPELISP_BIN=$tl ./scripts/check-codegen-target-parity.sh
scripts/ci-verify.sh
```

Run the tests that match the layer you touched; `scripts/ci-verify.sh --gates
<id>` reruns one gate with the gates it needs. On non-Linux platforms, scripts
that require native `as`/`ld` either no-op by design or should be run through a
Linux environment.

## Checklist for new coverage

The required `stage2-core-ir-dependency-boundary` gate runs
[`verify-core-ir-dependencies.sh`](../scripts/verify-core-ir-dependencies.sh)
with the converged compiler. It compiles the canonical frontend inspector with
`compiler-dependency-audit`, runs source and fact-stream fixtures, then checks
the complete shared IR closure across the supported target/cfg space. See the
[boundary decision](../docs/compiler-core-ir-dependencies.md) for authority,
scope, policy maintenance and diagnostic-cfg retirement. Extend its table-driven
fixtures for new dependency forms; retain the bounded resource report and
measure full gate cost when changing discovery or orchestration.

New behavior gets TypeLisp-owned coverage (see the implementation-language rule
in [`../CONTRIBUTING.md`](../CONTRIBUTING.md)):

- Pick the smallest useful layer: module-local assertion, smoke driver, inline
  test, corpus or case-file row, or script runner.
- Put structural compiler checks in the owning module's `*_tests.tl` companion,
  as small helpers or a `*-self-test` function; state optimizer and backend IR
  as `typelisp-ir` text.
- Prefer inline `(test ...)` items for source-local runnable checks; the
  inline-test gate picks them up automatically.
- Add or update a `src/tests/*_smoke.tl` driver when the module should be
  executable through the compiler boundary, and keep its dependency list in
  `tests/integration/native.manifest` (and the host fixture sections of
  `scripts/verify-integration.sh`) in sync whenever imports change.
- Add a `src/compile_manifest.txt` case when a new top-level module must
  compile on its own or pins a codegen marker.
- Add public command, package, docs, LSP, REPL, formatter, or platform cases to
  the matching `tests/cli/*.cases` file, and codegen-shape checks to
  `tests/codegen/*.cases`.
- Prefer naming conventions and representative examples in docs and comments;
  avoid maintaining long file lists that will go stale.
- Run the focused tests for the layer touched, plus `typelisp fmt --check`.

## Iterative AST wrapper removal

`compiler-ast-deep-wrapper-chain` in `src/tests/compiler_ast_types_smoke.tl`
checks bare leaves and mixed `Spanned`/`MacroExpansion` chains on both sides of
expression segment boundaries, including more than two full segments. Run it at
opt0, opt1 and opt2 alongside the native smoke's row-rewrite, truncation/reuse
and equal-ID/different-pool cases. Wrapper removal consumes each row before
reading the next and copies out the leaf without recursive stack growth.

`decls_module_scopes` and `serialize_module_scopes` run at opt0/1/2 on both
hosts. The former repeats one declaration expansion within two generated
modules and reimports a generated module. The latter round-trips shared enum
payloads through separate enclosing serializers and checks distinct struct,
string and scalar values. `decls_same_scope_incompatible` preserves a located
incompatible-output diagnostic for one module/canonical expansion identity.
`decls_explicit_module_scopes` combines local declarations with shared explicit
modules; `decls_explicit_module_tail_conflict` checks that replayed markers
still assign subsequent declarations to their explicit owner.
`decls_self_target_scopes` expands bare and bodied module switches in a module
that is also their target, in both import orders and with a same-module replay;
`decls_explicit_target_incompatible` keeps the shared target segment's
incompatible-output diagnostic across consuming modules.
The typechecker memo scope test complements its existing owner-isolation,
collision-probing, scratch-persistence and re-arm allocation checks.

### ELF64 relocatable input reader

`linker_elf_object_reader_tests.tl` and
`tests/linker_elf_object_reader_smoke.tl` share `self-test` assertions. Inline
and native opt0/1/2 tests embed all 24 GCC16/Clang22/GNU-as/TypeLisp object
snapshots and independent LLVM numeric projections; they launch no host tools.
The test-only `linker_elf_object_reader_test_dump.tl` renders stable physical
IDs, offsets, raw scalars, hex names, groups and note spans. It is not a linker
or public object-format CLI.

The corpus covers header/structured-prefix truncation, bad ranges/overlap,
strings/links/local boundaries, groups, SHNDX, notes/compression, all caller
limits, all relocation widths/unknown numbers, signed addends, real indexes
above 65535, raw byte names, opaque types, pointer-array priorities, interleaved
identities and bounded mutations. With `--cfg compile-profile`, allocation
assertions compare tiny/large payloads and retained-budget refusal; a consumed
allocation fixture verifies the counters are active.

`stage2-elf-object-reader-oracle` is a separate required Linux gate. Its
`scripts/verify-elf-object-reader-oracle.sh` compares every snapshot and recorded
projection with live `readelf -W -S -s -r -g -n`, plus LLVM's full numeric JSON
projection when `llvm-readobj` is installed. It preserves the whole corpus and
reports LLVM availability. Generation is oracle-only; follow
[`tests/fixtures/elf-object/README.md`](../tests/fixtures/elf-object/README.md)
for versions/options. Repository-rooted `tests/fixtures/...` manifest
dependencies preserve their relative location when smoke sources and companions
are staged; absolute/parent-traversal dependencies remain invalid.

### ELF64 shared-object metadata reader

linker_elf_dso_reader_tests.tl shares self-test with
src/tests/linker_elf_dso_reader_smoke.tl at opt0/1/2 on Linux and Windows.
Eleven embedded GCC/Clang/musl/GNU-as snapshots cover both hash formats,
GNU versions, weak/protected/TLS/IFUNC definitions, loader flags, needed
libraries and a sectionless DSO. Recorded readelf projections check every
exposed record.
The sectionless case also checks unchanged payload bytes and complete version
model parity with its independently checked sectionful producer.
The zero-address dynstr producer accepts unrelated unallocated string tables;
marking either table allocated must report its contradictory source field.

Keep own-hash versus independent linear-wire lookup checks, explicit/default
versions, absent versions, NUL-containing queries, missing hash tables,
physical provenance, all caller resource boundaries, every minimal-file
prefix, targeted pointer/hash/version/section corruptions and the finite
hostile wire corpus. Extended numbering and empty load segments are controls.
Run the smoke separately with --cfg compile-profile: its positive allocation
counter control makes the borrowed-payload allocation comparison meaningful.

stage2-elf-dso-reader-oracle is an additional required Linux gate using live
readelf -W -D -s --dynamic --version-info. Existing gates remain unchanged.
Its sectionless limitation and producer regeneration instructions are in
tests/fixtures/elf-dso/README.md. Normal/native tests invoke no external tool.

The empty-GNU-hash controls retain every undefined symbol using a SysV or
checked section count. Removing both count sources yields explicit unsupported
metadata. Do not infer symbol count from the distance to dynstr.

### Standalone backend source imports

`compiler_backend_source_tests.tl` checks the public source helpers with
qualified stdlib functions/types, declaration/expression macros, selected and
wildcard imports, and both target cfg presets. Its assertion body also runs
inside `compiler-backend-self-test`. Request tests carry explicit roots/user
cfg names through successes and failures and pin caller paths/import labels.
Nested jobs retain a published AST prefix, source name, builtin IDs, intern
generation and enclosing load-session owner. Import-free library controls retain
the native catalog's entry names. Success/failure controls also inspect private
prefix, dotted-path, provenance and surface-summary owners after retirement.

The four `backend_source_import_*` fixtures run in the native corpus at
opt0/1/2 on both hosts. `stage2-backend-source-import-context` additionally
builds a test-only source-helper driver and compares executable exit 42 and
empty output through assembly, serialized raw objects and the ordinary CLI.
The required gate performs 12 route checks per host. The allocation fixture
keeps assembly/CLI execution plus an explicit object-eligibility exclusion;
it must not execute an unadmitted raw image with #8317's placeholder runtime
symbols. The shared native-link helper links serialized objects with the same
entry, libraries and flags as its assembly path.
