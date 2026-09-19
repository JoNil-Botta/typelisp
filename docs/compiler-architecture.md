# Compiler architecture and CLI

This page describes the compiler pipeline and command-line surface. Run
`typelisp <command> --help` for the current option details.

## Architecture

```
Source (.tl)
    ↓  Lexer        → Tokens
    ↓  Parser       → AST
    ↓  Type Checker → Typed AST
    ↓  Lowerer      → IR (3-address code, basic blocks)
    ↓  Optimizer    → constant folding, GVN/CSE, copy propagation, DCE, LICM with loop preheaders, function inlining, strength reduction; opt-level 2 adds scalar register allocation
    ↓  Backend      → x86_64 assembly (.s)
    ↓  target tools → native executable
```

`AstType.CFunc` separates a native code address from an ordinary TypeLisp
function/closure descriptor. Its pooled `Func` operand records only argument and
result shape; its second operand records nullability and the unsafe-call effect.
The AST node keeps the existing 24-byte stride, while the runtime value is one
8-byte code address. Copying or storing that address must preserve the complete
`CFunc` type. A zero initializer is valid only for nullable modes.
Surface AST schema 10 records the pooled signature and all four modes; the
encode/hydrate selftest checks those facts after compaction and intern reset.
The reader records C signature references from pool nodes and inline types, then
validates them against the completed destination pool before publishing hydration.
A signature must reference an in-range `Func`, never a scalar or another `CFunc`.

Backend signature recovery reads `CFunc`'s pooled signature through the explicit
type-segment bases, using the same reader as extern signatures. Losing the
parameter list here can pass a wide aggregate's transport metadata as ordinary
register arguments. The migrated native C ABI fixtures cover register, memory
and hidden-result shapes through both direct and stored code pointers.

`lower-indirect-call` owns typed dispatch to the C ABI lowering path. Every
indirect call site uses that dispatcher; lexical provenance flags cannot choose
a different calling convention for the same type. Global
cells and external data symbols must first load their current value; neither the
cell address nor a C code address may enter closure-descriptor dispatch.
Checked bindings retain the complete type; their replay record stores only arena
owner and phase transitions. Argument compatibility compares types directly,
without a separate syntax walk to infer a raw pointer provenance.
Environment caches and scoped lookup results likewise carry no raw-pointer flag.
They preserve the complete stored type alongside independent unsafe-declaration
and ownership markers. The cache raw-layout smoke checks the shadow-array
address, flags and parent links against typed field access on full and layered
caches; its explicit byte offsets must change with the cache record.
`tc-source-type-policy-ok` validates every source `CFunc` through the shared C
ABI checker and then visits its signature through the existing source policy.
This covers unused parameters, fields, lambda types, initializers and nested
annotations without a second declaration or expression traversal.
`tc-check-extern-native-signature` checks explicit C pointer signatures and
borrowed-Slice boundaries even on default native declarations. The broader
explicit-C ABI checker remains separate because private runtime declarations
also use native contracts outside the ordinary C signature subset.

Vector reduction sources are read-only IR operands. AVX2 four-lane signed
`i64` min/max needs an accumulator, a lane sibling and a comparison-mask
scratch family: its second comparison must not write through the source's XMM
alias. `compiler-reg-vector-reduce-mask-scratch?` owns this shape distinction;
`VectorReduceMask` is ordinal 2 in the modeled scratch plan. Emission consumes
planned homes through the shared preservation-aware scratch selector, so an
occupied home receives the same save/restore contract as other scratch roles.
AVX-512 native min/max and the other reduction shapes retain two scratch roles.

The lowerer's checked expression dispatcher delegates complete families to
focused helpers. The [expression-family ledger](compiler-lowering-dispatch.md)
records routing, residual inline bodies and the state/evaluation/provenance
contract for those boundaries.

Compilation is one whole program per executable with import-graph dedup
(each module typechecked once per program). Package dependencies are
codegen'd once into archives; an in-process session cache warms compiler
pools across compiles within one process (batch and LSP paths).

Lexer tokens and unspanned reader nodes are scan scratch. Their geometric
growth replaces dedicated storage after moving the live prefix, then retires
the superseded owner and restores the caller's active arena. Token storage is
not published until scanning returns. Unspanned reader children and pending
builders retain indices rather than array addresses. Each reader array has its
own owner so growing one cannot repeatedly allocate the other's capacity. The
reader scratch profile row sums both owners. Token and reader literal payloads
remain in their source/interner owners. Growth therefore preserves records and
indices without retaining all previous capacities. The separate spanned reader
pool also owns declaration/member origins and must follow its existing retained
origin handoff instead. Whole-load scan release still empties all scan scratch
owners, while reusable sessions retain only their current capacities.

The ordinary, PIC and owned package driver paths share checked-pool ownership through
`compiler-driver-state-begin-checked-lower!` and
`compiler-driver-state-finish-checked-lower!`. The handoff records its original
allocation arena, source-pool owner and destination pools in the driver's
retained surface arena. Generation or macro compaction may retire the source
arena before lowering returns, so bookkeeping must not live there. Finishing
copies failure diagnostics to retained storage, adopts committed pools or
destroys unused destinations, restores a live allocation arena and clears the
lowerer's handoff. Callers consume the returned result and pool context;
they must not duplicate these release and adoption decisions.

Package inline-test preflight owns AST/type pools and scratch storage per
source file. Its cfg-name snapshot owns copied strings across per-file intern
retirement. Pool-backed caches and derived dependency surfaces are cleared
before the pools are destroyed; replacement session carriers live in the
enclosing arena. The scalar scan for inline tests also releases its file text.

Package doctest discovery uses a separate frontend lifetime through
`compiler-driver-load-package-paths-with-runtime`. Earlier frontend consumers
must be finished: discovery resets reader origins and analysis caches, while
the caller retains manifest/root/dependency strings and its admitted catalog.
The temporary load session
borrows the enclosing package's admitted dependency catalog and owns its parsed
AST/type pools, interner, caches, and hydrated dependency surfaces. It copies
ordered path strings or a diagnostic into the caller's arena before restoring
the enclosing session, interner and builtin state and releasing those temporary
owners. The serial parser advances the active interner's scalar cursor, so this
load session uses the serial adapter that captures that live cursor. Binding an
explicit pre-parse interner snapshot here can silently omit imported modules.
Returned paths use absent owner/provenance IDs (`-1`): the builtin for the empty
spelling is itself an intern ID and cannot cross this
boundary. Releasing the borrowed catalog would invalidate the enclosing
package's native mappings and is forbidden.

After discovery, package doctest file reading and fence extraction use another
scratch lifetime. Only live example/error rows, including runnable output
expectations, are copied into the checker arena. Source bytes, line buffers,
and fence-scanner temporaries are released before typechecking. Both source
and file callers share the same extracted-example checker, preserving order,
counts, diagnostics, and the existing adjacent-path deduplication rule.

The lifetime tests in
[`compiler_package_discovery_lifetime_tests.tl`](../src/tests/compiler_package_discovery_lifetime_tests.tl)
exercise arena reuse, path and diagnostic ownership, session restoration,
subsequent checking, target changes, cfg snapshots, admitted native mappings,
and runnable/failure metadata. Ordinary
`clone` is not a valid way to escape flat-node compiler ASTs: their pool-backed
payloads require the loader's pool-aware compaction or an explicitly owned
pool lifetime.

Package runtime emission uses `CompilerDriverPackageRuntimeScope`: its carrier
lives in an outer job arena, while source pools, parser allocations, interner,
analysis state and derived dependency surfaces have explicit temporary owners.
The child loader borrows the parent's admitted catalog. After every load result,
including failed imports, the driver captures the live pool/interner/builtin
state before cleanup can inspect it. It captures again after path/export
preparation, before generation installs that explicit interner. Published
dependency facts are copied into the retained runtime state before source
retirement, preserving composite-prefix status and clone observations. Cfg snapshots re-intern copied names;
`sym-i64-copy` detaches the import environment's backing chain while its symbol
IDs remain valid. Linker strings are deep-copied into the caller's arena.

Runtime lowering shares the ordinary/PIC checked-pool handoff. Both ordinary
functions and generated package SPMD specializations escape through
`lower-function-seq-escape-to-ir-arena` before checked frontend retirement.
The generated specialization path must retain complete parameter, block and
instruction storage, even when no ordinary function contains an SPMD call.
Complete object bytes, side assembly, diagnostics, export source and encoded
checked surfaces
belong to the enclosing arena before scope release. Release restores parent
selectors in that arena, then destroys only child-owned storage, including the
backend's private lazy/representation arenas. It is idempotent so early loader
errors and the final artifact path share one cleanup owner. The backend's
terminal release API forbids later emission through that state and never
releases its borrowed emission or carrier arenas. Linux direct-object emission
also releases its temporary side-assembly backend after rendering; that state
has private lazy storage separate from the runtime scope's primary backend.
Native export compilation starts only after runtime cleanup. A failed checked
lower releases a still-live source/checked pool before replacement; a rollover
abort must not revisit its already destroyed original context.

Dependency verification records `runtime-finished` from the runtime child's
load session immediately before its first release. Surface hydration and skip
counters belong to that child and cannot be read from the restored parent.
The later `finished` record describes the parent's admitted catalog before
mapping release. Verification must retain both boundaries without extending
frontend storage lifetimes or treating cleared parent counters as runtime work.
The package surface capture's fixed state cell survives those lifetimes too.
Its expanded AST payload is consumed before frontend retirement; encoded bytes
and copied error text belong to the result arena selected when capture starts.
Taking a result detaches its value before clearing the cell, so both success
and failure can leave an inactive state after the former result arena retires.

The standalone prelude producer is owned beside
`tools/embedded-stdlib-tlci/build-surface.tl`. Its cold loader, typechecking,
result carriers and payload encoder must not be duplicated in the root compiler
package. `compiler_prelude_surface_producer.tl` shares only deterministic
module-set construction with the package producer: deduplicate paths and sort
by surface identity order. The compile manifest records this ownership; exact
package-root lint detects uncalled producer declarations, while embedded-stdlib
and package-surface parity gates exercise the real producer entries.

The runtime lifetime tests cover repeated checked errors, macro errors, failed
imports after a successful import, parent restoration, bounded direct-object
side-backend retention, and emission at all optimization levels for both targets. The copied environment test destroys the
source arena and checks duplicate bindings, zero values and snapshot isolation.
These focused contracts complement complete package build and platform gates.

Test batches and package tests isolate each file in a `TlTestEntry`. The frame
installs its own AST/type pools, load session and serial typecheck job while
borrowing paths and package metadata from its caller. Lowering and one-shot
emission retain explicit state until their output has been consumed, then
release private indexes and operand/representation tables. Complete backend
results remain in their outer emission arena. The entry finish operation clears
aliases before freeing pools, retires all job-owned cache payloads, restores
parent selectors and destroys the entry arena on both success and diagnostic
returns. This lifetime applies to every ordered entry; it does not split or
restart the batch compiler.

Mutable typecheck caches, indexes and traversal state belong to the compiler
job's `TcJobState`, never to process-wide cells, so resetting or destroying one
job cannot disturb another. A value that is a pure function of intern ids is
not cached at all: a stdlib comptime syntax type is recognised by decomposing
the structural module key of its canonical id, and comptime helper prefixes are
compared with the builtin ids directly. Generation-stamped mirrors of such
values only add state that must then be reset and isolated. The families that
still await migration are tracked in #4960.


Memory-class aggregate expressions carry addresses into inline storage.
`lower-local-assignment-value` gives a loop-carried memory-class local its own
inline storage before rebinding it. The source can arrive through a field,
enum payload, fixed-array projection, conditional merge, or nested loop; the
copy must not depend on incomplete address-provenance tracking. Otherwise a
later call can overwrite a retained result slot even at opt0. Raw pointers
copy only their address. The native `loop_carried_enum_payload_snapshot` and
`loop_carried_raw_read_snapshot` fixtures guard this boundary on both targets
at every optimization level. Address generation uses `lower-emit-gep`, also
shared by byte-offset projections through `lower-gep-byte`.

Address-exposed register groups own contiguous stack pairs indexed by final
variable ID. In a function that exposes any group address, all group second
words use that canonical pair region; mixing a one-word-stride map with
exposed pairs aliases distinct live values. Ordinary first words remain in
the scalar slots. A zero-storage addressable-group bitmap proves that a
function can retain the compact second-word map, preserving ordinary-only
code generation. The existing two-words-per-variable frame reservation covers
both modes. The backend's exhaustive mixed-exposure test checks operand
disjointness, and `mixed_group_stack_homes.tl` checks writes across real calls
at opt0/1/2 on both native targets.

CFG rows and ordered optimizer integer collections share the existing dense
`OptLabelSet` storage. Its name reflects the original label-set users;
`opt-label-cons` preserves duplicates, while `opt-label-add` applies membership
semantics. Backing slot zero records the high-water length, so extending a
retained prefix or tail copies before writing and preserves sibling views.
Storage grows by element count, including for sparse IDs and negative values.
Logical traversal stays newest-first; CSR emission reads physical slots in
oldest-first order directly, without constructing reversed intermediate lists.
The integer-sequence and CSR tests cover growth, branches, duplicates and offsets.

Call-memory root scanning, summary accumulation and write predicates read the
live prefix of dense block sequences directly through the block sequence accessor.
These internal shallow reads require valid storage and an index below logical len.
The instruction helpers remain authoritative for effects and provenance. Root
updates retain forward order and both existing passes; unresolved candidates and
successful predicates stop before reading later blocks. No scanner mutates block
storage or consumes spare capacity. The linked/dense/mixed differential fixture
covers retained inputs, delayed definitions, unstable bindings and early exits;
this traversal optimization leaves the wider block-storage migration in #5729 open.

Affine folding keeps one mutable fact table per function: local vreg IDs index
compact binding slots, and only live bindings are scanned for key/base
invalidation. Every block starts with empty facts; the cumulative 512-binding
budget also clears facts without freeing or replacing their backing storage.
Invalidation does not refund that budget. No caller retains an older environment
snapshot, and the table dies before the function's optimizer arena is rewound.
The affine storage reference/growth tests and optimizer smoke driver protect
these rules. Reuse the existing generated core vectors for compact payloads;
do not allocate wide records for every possible local ID or rebuild cons chains.

The checked inliner's literal-argument scan borrows dense block storage directly.
It visits blocks and instructions in forward order without building linked
copies. Its result includes every matching definition and the last integer
literal, even after a duplicate makes specialization ineligible. Keep traversal
separate from that admission decision; stopping the scan early changes its
recorded result. This read-only path does not change block ownership or the
remaining mixed block-list representation.

Register analyses share one ownership budget: the conservative number of
32-bit-set words per instruction is compared against 32,768 words (256 KiB),
using division to avoid multiplication overflow. Small analyses allocate in the
existing function/planning arena. Larger scalar register plans own temporary
liveness and greedy-allocation storage in a separate arena. Its escape boundary
copies retained assignments,
intervals, eligibility bits and split records into the caller's arena, including
rematerialized String/Bytes values through the canonical IR value copier. The
original type view retains its job-owned representation index and profiling
metrics; the trace journal is copied before the planning arena is destroyed.
Typed scalar reconstruction of split records makes an added owned payload or
variant require an explicit update to that boundary.

Eligibility calculation, rematerialization interval selection, stack coloring
and final scavenger interval selection use that same budget to reclaim large
analysis temporaries after copying their small result. The budget selects only
allocation lifetime; it never reduces analysis precision or optimizer work.
Avoid unconditional arenas for small analyses: measured per-self-compile arena
creation grew over tenfold and materially regressed ordinary compile time.
Final scavenger intervals still describe the
final emitted IR at instruction precision. Call-hole retry context retains its
edge-precise liveness while candidate rewrites still consume it. These lifetimes
bound overlapping analyses within a large function; the existing function and
assembly-stream arenas continue to bound accumulation across functions.

Optimizer substitutions must prove their per-variable definition requirements;
late IR may still contain mutable locals when SSA construction declines a
function. `opt-def-counts-*` counts entry parameters and all destinations through
the verifier's canonical instruction classifier. The post-prune uniform-phi
pass uses those counts before forwarding literals and admits each destination
once into its frame-sized worklist. Its `uniform_phi` observation is available
through pass tracing and `--dump-ir after-uniform_phi`.

The compiler also has a pure, versioned incremental-query identity layer. It
canonicalizes typed source, logical-name, dependency, package/stdlib,
configuration, macro/comptime, target, and ordered-child inputs into a bounded
binary transcript and exact SHA-256 fingerprint. The layer is relocatable and
independent of cache storage: callers supply authority-checked package-relative
paths and nominal compiler/child identities, while event capture, invalidation,
result serialization, and reuse policy remain separate compiler services.

Aggregate declaration markers live in `AstDeclMeta` in
[`compiler_ast_types.tl`](../src/compiler_ast_types.tl), separate from runtime
layout. Parsing and surface hydration share its runtime metadata constructor;
unmarked runtime declarations reuse the singleton, and unchanged marker updates
do not allocate. Generated-declaration reuse in `compiler_specialize.tl` compares
these semantic flags even when the aggregates have identical ABI. The existing
AST wrapper, surface roundtrip, and specialization selftests guard these rules;
serialized metadata changes also require a surface-AST schema version change.

`Module` and `Decls` macro output share `macro-wrap-generated-decls` in
`compiler_typecheck_core.tl`. Ordinary generated imports carry namespace effects
without a visible declaration name; retain their generated metadata so the
fixed-point walk resolves them through the canonical loader before typechecking.
Materialization uses the loader's existing module/item classifier. Complete
in-memory programs retain their provided module identity without becoming file
requests. Generated import spans and declaration paths both refer to the macro
call site; materialization failures preserve the dependency diagnostic and add
that call site as a structured related location.

Macro surface searches borrow declaration records while inspecting their module,
name and kind. A rejected candidate must not clone signature or parameter-list
payloads. `compiler-load-surface-decl-list-borrow-at` ties the view to its source
list; the owning accessor remains available for retained payloads. A selected
macro call result copies its parameter and return-type payloads before leaving
the borrowed view. Summary reset must not invalidate that retained signature.
The surface-macro smoke test checks first/last/missing names, interner identity,
and retained selection across summary destruction.

The loader's path-aware namespace validators serve source imports and the
completed macro expansion. They run at the expansion boundary, after generated
imports have become canonical markers. Dotted-alias keys combine the importer
module and explicit alias; values are canonical expected module identities.
Repeated same-module bindings are idempotent. Empty generated aliases are
unqualified markers, not dotted names. Selected/wildcard imports share the
loader's unqualified-name collision rule. At the completed expansion boundary,
that traversal also requires selected items to exist; loading alone cannot
assume declaration generators have finished. Errors use the marker's physical
path and span. Each scan uses temporary maps that are not cached; composite-key
interning is published to the job's intern owner before handoff. The generated
import runtime fixtures and interleaved loader-state smoke guard these contracts.

Handwritten runtime, startup, and direct-object x86-64 code is covered by the
closed [compiler-owned executable template registry](compiler-x64-executable-templates.md).
It records mutation-sensitive source identities and typed control/frame events
for later native-code certification.

Expression node IDs belong to an AST pool. Literal analysis in
`compiler_typecheck_core.tl` snapshots the context's expression owner for its
read-only walk and shares the AST unspanner with other structural consumers. The
scalar owner accessor borrows the context field directly; it must not copy the
complete pool aggregate merely to read its segment-base token.
An unrelated installed pool must not change literal classification, contextual
numeric types, or retained source provenance. The explicit compatibility route follows
its selected pool; macro-capable walks must resolve their owner again after a
possible pool install. The `tc-literal-expression-pool-isolation` inline test
covers colliding IDs, nested source views, expansion wrappers, and contextual
overflow rejection.
The call-argument type memo follows the same rule: `tc-call-arg-fact-key` peels
expansion wrappers through the caller context's expression owner, because the
key indexes that context's body-fact table and a colliding view in another pool
is a valid but different key. The key stays the immediate source-view payload,
and an unwrapped view is keyed without reading any pool. The
`tc-call-arg-fact-key-pool-isolation` inline test covers it.

### Package direct-object routing

Package route preflight reads live declarations once, before lowering.
`build-package-emit-preflighted-runtime` then consumes the chosen route and one
`ResultCompilerDriverLowered`. Linux object emission, Windows batch emission,
and assembly fallback share that boundary; none accepts source declarations or
re-enters lowering. The driver provides lowered-result emitters, with no second
package-specific load/lower wrapper chain.

Before runtime lowering, `build-package-tlci-capture-exports` records callable
metadata as canonical TLCI text, sorted macro identities as owned strings, and
the complete generated transformer source. `TlciNativeMacroCaptures` contains
AST body and parameter references, so it stays inside that capture operation.
Capture runs in a disposable scratch arena: collectors, temporary rendering and
AST-backed macro captures do not survive it. Only the final metadata text, each
catalog name, transformer source or diagnostic is copied into the caller owner.
This prevents capture intermediates from remaining live through opt2 inlining.
Later TLCI finishing reads only the captured text/catalog and checked surface;
it must not revisit source declarations or dereference source intern IDs.
The native producer's capture-based adapter and
`embedded-native-emit-package-source` share one native compilation and image
emission implementation. Runtime diagnostics and checked-surface failures still
precede deferred export metadata errors. The export lifetime tests destroy and
reuse the original parser/interner storage before emitting both target images.

`build-package-prepare-runtime` and its owned-scope adapter in
`build_cli_core.tl` share package route selection through `BuildPackageDirectObjectRequest`: target, artifact kind,
backend mode, debug policy, resource policy, strict policy, and loaded inputs.
Its result contains object bytes and complete side assembly, valid fallback
assembly with a closed `CompilerDirectObjectFallbackReason`, or a diagnostic.
Callers must not recheck eligibility or infer the route from diagnostic text.
The strict helper rejects every fallback before external tools or publication.

Package policy is distinct from serializer capability. Source and package ELF
consumers share `source-tool-linux-direct-object-eligibility` and
`source-tool-render-linux-direct-object` in `build_run_core.tl`; package code
only translates the artifact kind. COFF capability remains owned by
`compiler_windows_coff_core.tl`. Reason categories and bounded context are
rendered centrally in `compiler_backend.tl`, without parsing serializer errors.
The package freshness gate checks the shared ELF boundary, including mutations
that bypass it; inline tests cover policy combinations and malformed images.

The fresh-artifact pipeline prepares the runtime once for checked-surface
capture, then passes that same result to artifact finishing. Finishers accept
bytes and text, not AST/IR inputs; they cannot lower again or regenerate side
assembly. The package COFF request always asks for side assembly, and a missing
side artifact is an internal error. The freshness gate rejects mutations that
restore preparation or frontend inputs at this boundary.

Fallbacks retain assembly, without retaining the object image. Future archive
export summaries must be derived at
the successful-image boundary before compiler arenas retire, then returned as
bounded owned data alongside bytes. This preserves the route contract while
the backend migrates to shared machine records; it does not broaden object
eligibility or introduce public strict-mode options (#7452, #7395, #7032).

## Performance gates

Generated code is compared with `clang -O2` using paired cases under
[`../benchmarks/`](../benchmarks). Compiler and generated-code performance is
tracked with deterministic executed-instruction baselines under
[`../perf/`](../perf), avoiding wall-clock noise in required CI gates.

Required verification has one top-level metadata authority,
[`scripts/ci-gates.tsv`](../scripts/ci-gates.tsv), consumed by both full execution
and host inventory listing. The runner binds stable IDs to commands and rejects
incomplete or failed execution before reporting success. Nested compiler,
corpus and artifact-provenance invariants stay in their existing owners; a
metadata row alone does not establish them. See the
[ledger boundary](../scripts/README.md#core-development-loop) before changing CI
structure or introducing independent scheduling.

## CLI

Inline-test harness construction prunes runtime declarations before typechecking.
An unresolved dotted name may be an imported member or a projection from global
storage, so reachability retains both the final member and the first source
component. The normal fixed point then retains a referenced global's initializer
dependencies. Hygiene and module qualification are normalized against the captured
intern session; dotted projections must not consult another installed pool.
Unrelated globals remain pruned. The global-field inline fixture and harness
retention test guard this boundary.

```text
Synopsis:
    typelisp - A typed Lisp/Scheme dialect with x86_64 backend

Usage:
    typelisp <command> [options]
    typelisp <command> --help

Commands:
    typelisp build          Build a source file or package artifact
    typelisp check          Type check a source file or package
    typelisp clean          Remove build artifacts
    typelisp compile        Generate assembly or IR
    typelisp doc            Generate documentation or run doc tests
    typelisp explain        Explain a diagnostic code
    typelisp fmt            Format source files or a package
    typelisp init           Scaffold a package in the current directory
    typelisp inspect        Inspect a TypeLisp comptime image
    typelisp lint           Lint source files or a package
    typelisp lsp            Start stdio language server
    typelisp new            Scaffold a new package directory
    typelisp repl           Start minimal stdio REPL
    typelisp run            Compile, link, and run a source file or package
    typelisp test           Run or check inline tests
```

Common options include `--target linux-x86_64|windows-x86_64` (Linux is the
default output target; `test` defaults to the host), `--backend-mode
scalar|avx2|avx512`, `--opt-level 0|1|2` (0: no IR optimizer; 1: cheap
stack-only passes; 2: full optimizer with register allocation and inlining —
levels never change program semantics), `--manifest-path <file>`,
`--stdlib-root <dir>`, `--locked`, `--update-lock`, and `--cfg <name>`. Run
`typelisp <command> --help` for command-specific help. The REPL remembers
top-level declarations and evaluates bare expressions by compiling a scratch
program through the real build/run pipeline — there is no interpreter.
`.load <file>` adds a source file's declarations to the current session after
checking the combined session. Scalar results are printed directly; structs,
enums, tuples, and fixed arrays use the stable fallback `<value: Type>` because
TypeLisp does not currently provide runtime reflection for their contents.

Human-facing `check`, `compile`, `build`, `run`, and test-preflight failures
render error codes, source locations and snippets, carets, secondary labels,
and available help/notes. LSP and other machine consumers keep their structured
or stable flat diagnostic representations. Diagnostic codes are append-only:
published numbers are never renumbered or reused. The currently classified
typecheck codes are `E0201` (unbound name), `E0202` (arity mismatch), `E0203`
(non-exhaustive match), `E0204` (unknown struct field), `E0205` (region
escape), `E0206` (type mismatch), `E0207` (borrow violation), `E0208` (move
violation), `E0209` (unsafe context required), `E0210` (lifetime mismatch),
`E0211` (resource ownership violation), `E0212` (arena ownership violation),
`E0213` (invalid pattern), `E0214` (SPMD restriction), `E0215`
(invalid storage place), `E0216` (control-flow misuse), `E0217` (thread-safety
violation), `E0218` (compile-time constraint), and `E0219` (unsafe callable
effect erasure). Run
`typelisp explain <code>` for a description, minimal failing
example, suggested fix, and related references. Code lookup is ASCII
case-insensitive. `typelisp explain --list` prints the registry and
`typelisp explain --search <term>` searches its titles and prose. The generic
`E0100` parse and `E0200` unclassified typecheck entries also have complete
explanations. The checked-in ownership and construction-site inventory is in
[diagnostic-codes.md](diagnostic-codes.md).

Disposable measurements and diagnostics belong under `target/exp/<name>/`;
`typelisp clean --experiments` removes that subtree at the nearest package root
without touching bootstrap or package build outputs.

## Async process ownership

Async process start reserves a generation-tagged, boxed registry authority before
preparing descriptors or spawning. Reserved entries own no native resources;
cleanup releases their slots without issuing a wait or close. Successful exec
moves the reservation authority to the returned child and publishes its PID and
capture descriptors while holding the registry lock. The lock is never held
across native process operations. Cloned or fabricated boxes cannot claim either
reserved or live entries because their identities do not match. The Linux process
fault gate covers full capacity before spawn, failure cleanup, concurrent
reservation reuse, cloned reservations, reverse waits and stale live tokens.
A separate mode of the same fixture runs concurrent native starts, failed execs
and waits without the single-threaded fault hooks; both modes check descriptor
and child cleanup.
