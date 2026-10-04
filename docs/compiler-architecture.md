# Compiler architecture and CLI

This page describes the compiler pipeline and command-line surface. Run
`typelisp <command> --help` for the current option details.

## Architecture

```
Source (.tl)
    ↓  Lexer, reader → spanned s-expressions (lex.tl, read.tl)
    ↓  Parser       → AST
    ↓  Type Checker → Typed AST
    ↓  Lowerer      → IR (3-address code, basic blocks)
    ↓  Optimizer    → constant folding, GVN/CSE, copy propagation, DCE, LICM with loop preheaders, function inlining, strength reduction; opt-level 2 adds scalar register allocation
    ↓  Backend      → x86_64 assembly (.s)
    ↓  target tools → native executable
```

Linux and Windows share one lowerer and one backend. Target choices live in
four places:
- the lowerer's target-aware C ABI shapes;
- the target policy (`compiler-backend-target-policy-new`) and its facts;
- the ABI tables in `compiler_abi.tl`;
- the platform leaf modules (`compiler_backend_runtime_{linux,windows}.tl` and
  `compiler_backend_object_target_{linux,windows}.tl`).

Shared emission reads those facts and never tests the target itself.
[`scripts/check-codegen-target-dispatch.sh`](../scripts/check-codegen-target-dispatch.sh)
enforces the boundary; [`src/TESTING.md`](../src/TESTING.md) (*Cross-Target
Codegen Parity*) describes its rules.

The freestanding Linux runtime installs a zeroed TLS mapping before global
initializers and at each native worker entry. FS:0 holds the mapping's thread
pointer; named TPOFF relocations locate the arena pointer, optional backtrace
bounds and one private storage word. `tl_thread_local_word_addr` exposes that
word through an unsafe native declaration. Its address belongs to the calling
thread, survives arena changes and must never escape to another thread.
Issue [#8638](https://github.com/JoNil-Botta/typelisp/issues/8638) consumes this
primitive for the private I/O error channel; Windows uses its native TLS API.

`compiler_module_name.tl` owns the complete dotted import-name contract used by
both the parser and LSP: nonempty components, no path separators or colon, and
no final `.tl` suffix. It preserves the existing byte-level name predicate;
source tokenization still belongs to the lexer. The LSP classifies incomplete
editor prefixes separately and resolves only complete names at token boundaries,
so an unsupported byte cannot turn an invalid operand into a valid prefix.

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

Borrowed pattern bindings share one type/lowering contract:
`tc-borrowed-binding-type` copies `Copy` parts, projects boxed storage as a
shared reference, and otherwise retains a reference to the part. Lowering uses
`lower-borrowed-binding-expr` for enum, struct, tuple and array name patterns;
memory-class copies need independent storage, while String references load the
stored handle before forming a `str` view. Scalar enum copies may retain their
payload address only when `lower-deferred-copy-scan` proves every read precedes
any possible memory write. Calls, stores and cleanup boundaries invalidate that
proof; loops, captures, address-taking and unmodeled uses require an eager copy.
Deferred IDs name fresh locals and keep their by-value type. Reading one emits
a load, and borrowing one first copies the loaded value into its own storage.

A direct call argument may explicitly borrow a temporary. Its operand is a
by-value position evaluated in argument order, and its reserved lifetime ends
with the call. Typechecking rejects any result or mutable referent that could
retain that lifetime. The nested-call record is restored on both success and
error. Lowering keeps storage through the call and records owned cleanup in
the existing `LowerArgWriteback` sequence, reloading mutable register-class
storage before cleanup. Such a call cannot become a tail call. A later argument
that can leave early is rejected when it would bypass an earlier temporary's
cleanup; cleanup-containing aggregates without their own disposer are rejected.

Vector reduction sources are read-only IR operands. AVX2 four-lane signed
`i64` min/max needs an accumulator, a lane sibling and a comparison-mask
scratch family: its second comparison must not write through the source's XMM
alias. `compiler-reg-vector-reduce-mask-scratch?` owns this shape distinction,
and emission takes the mask from the scavenger as a third XMM scratch that
excludes the source, accumulator and sibling. AVX-512 native min/max and the
other reduction shapes use two scratch registers.

A function's frame is laid out before its body is emitted. Below the slot and
maximum callee-save area it holds, from the top down: the SIMD staging region,
the cycle-temp slots, the emergency slots, and, at the bottom, the outgoing
stack-argument area. A pre-body census (`compiler-backend-simd-scratch-request`
over every instruction) sizes the staging region to the largest request.
- Nothing stages outside it: variable-shift fallbacks, gather reassembly,
  shuffle staging, and AVX2 predicated and tail-mask lanes all address it
  through `compiler-backend-simd-scratch-address`, and no SIMD sequence moves
  `%rsp`. The rsp/FPO rebase, red-zone anchoring, CFI and SEH therefore see one
  frame, and a call from a staged sequence, such as shuffle's selector abort,
  leaves from the ordinary frame state.
- The region's size and frame offset are function frame state
  (`compiler-backend-scratch-i64-simd-scratch-*`), next to the cycle-temp and
  emergency extras.
- A function that stages nothing, including every scalar-mode function, plans
  no region.
- Each staged route claims its bytes. A claim beyond the plan fails at its
  instruction, and the region the body used must equal the plan (#7497).

A function body's blocks are one dense `CompilerIrBlockSeq`:
`CompilerIrBlockList` has only its `Array` arm. Walkers borrow the live blocks
as a slice (`compiler-ir-block-list-view`) and match it with slice patterns.
Passes that rebuild a body push into one `CompilerIrBlockBuilder` sized from
their input. Appending a list copies it, so a walk must not append each block's
rewrite onto an already-built rest.

Every `CompilerIrFunction` states its calling convention as a
`CompilerIrFunctionAbi`: `Ordinary`, or `SpmdPrivate` for a generated
same-program SPMD helper (scalar, AVX2, AVX-512, and package producer helpers
alike). The private descriptor, `CompilerIrSpmdPrivateAbi`, is immutable facts
under its own schema (`spmd-private-v1`, distinct from the imported catalog's
`spmd-call-v1` row): callee, backend, lanes, every physical parameter in
signature order with its ordinal, role (active mask; source parameter with its
source ordinal, value class and source type; appended index base) and physical
type, the index mapping (none, a reused varying source parameter, or the
appended base), and the result class and type. Lowering builds it once per
helper from the helper's emitted signature and argument classification, and
every same-program `SpmdCall` to that helper carries an equal copy through
`CompilerIrSpmdCallOrigin.Private`; imported calls keep #7317's catalog row.
Every pass that rebuilds a function passes the matched ABI through, and arena
escapes deep-clone it with the pool-aware `compiler-ir-clone-function-abi` and
`compiler-ir-clone-spmd-call-origin`. `compiler-backend-validate-program`
admits a program on both the assembly and object paths only after
`compiler-ir-spmd-private-abi-program-error` accepts it: each helper's
descriptor against its own signature, each call's payload against its
descriptor, and each call's descriptor structurally equal to its callee's.
The optimizer's per-call integrity check applies the call-side half. Backend
and register-allocation decisions still read generated helper and parameter
spellings; #7493 moves them onto the descriptor.

Source-known small helpers inside `foreach` preserve call-by-value before
their bodies are substituted. Arguments whose value or effects cannot be
rematerialized are bound to fresh function-owned locals in source order.
Variable reads require that snapshot even when the read itself cannot fault:
a later argument or the helper body can change the variable. Argument
initializers retain caller spans; body operations retain their original spans.
The direct-map planner represents these ordered bindings with
`LowerVectorMapValue.Stage`. Its emitter evaluates the staged value before
the body, and local reads resolve through the existing value cache. Range
proofs, masks, gather checks and scalar tails inspect both parts, including an
unused binding; staging must neither drop an argument's checks nor introduce
effects on inactive lanes.

SIMD `foreach` plans address their array operands as sequence variables: a
dynamic-array descriptor, or a native Slice register group (data pointer, then
length). Fixed arrays reach the same plans through views, not a path of their
own: after same-program helper inlining, `lower-spmd-array-views` gives every
fixed array (global, local, or behind `&`/`&mut`) whose each body occurrence is
an element read or store one Slice view formed in the preheader from its
storage pointer and static length, and rebinds the name to it for the body.
The view aliases the array, so element accesses and bounds checks are
unchanged; any other occurrence keeps the array binding, and a shared reference
never gets a writable view (#8346).

Under debug info (`--debug`), lowering also builds the debug type graph
(#8237): one target-independent description of every type a debug binding can
have, which the DWARF and CodeView emitters lower without reconstructing a
layout or asking the typechecker. Until the binding table (#8236) lands, its
roots are every function's parameter and result types and every `let`
binding's type, interned in lowering order into a job-owned
`CompilerLowerState` cell in the job's own arena. Nodes (`CompilerDebugTypeNode`
in `compiler_ir_types.tl`) are dense and preordered: scalars; structs and
tuples with field offsets and register-resident words; enums with an i64 tag
at offset 0 and variants in declaration (tag) order with payload offsets;
fixed arrays; pointers; `{data, len}` views for borrowed Slices and bytes;
handles to a `{data, len}` header for String, str, dynamic arrays and borrows
of str or a dynamic array; function pointers; and forward nodes, so a nominal
type reached again while its own layout is being built never forms a cycle.
Every struct and enum layout comes from `tc-inline-aggregate-layout-for-id`,
and tuple offsets follow lowering's own addressing. `--debug --verify-ir`
re-checks each node against independent typechecker queries (type size and
alignment, member offsets looked up by name, tuple offsets from the
typechecker's sizes) and fails the compile on the first disagreement. Without
debug info nothing is recorded.

A rank-2 `foreach` is `AstForeach.Foreach2` (surface schema 16, expression
tag 89): the outer coordinate's name, type and bounds, then the inner one's,
then the body, so binding order and ordinal survive every AST walker. The
SPMD checker binds both coordinates varying and read-only with role
`ForeachCoordinate ordinal begin end body-id`; the inner role carries the
header's inner bounds when each is a literal or a variable the body never
assigns. The body id lets the proof reject uniform offsets that change
between instances, including assignments from `foreach-active`. Offset
expressions use the shared child schema and accept only closed scalar
operations over literals and unassigned outer bindings; memory reads and
calls need a scalar captured before the domain.
While a rank-2 coordinate is local, destination and masked-branch indexes go
through the row-major proof (`tc-spmd-row-major-index?`) instead of the
rank-1 rule; a nested domain marks the coordinates outer and a helper argument
drops the role, so neither can prove a row-major write. `lower-foreach2`
desugars the domain to private bound locals, emptiness tests, checked span and
product traps, and nested `while` loops in every backend mode (#7190); native
row-local gangs are #7191.

Borrowed aggregate patterns share `lower-bind-element-access`: a String name
binding loads the stored handle to expose a `str` view, while nested aggregate
patterns retain the address of inline storage. Struct fields follow the same
access rule as tuple slots and array elements, preserving the borrow lifetime.

The lowerer's checked expression dispatcher delegates complete families to
focused helpers. The [expression-family ledger](../docs/compiler-lowering-dispatch.md)
records routing, residual inline bodies and the state/evaluation/provenance
contract for those boundaries.

Raw data-pointer return analysis requests a `CompilerLowerRequest` with a
`PointerProofRequest.Requested` owner. Standalone callers use
`lower-compiler-source-with-request`; driver callers install the request on
their explicit lowering state before checked lowering. The specialized,
typechecked function boundary records a graph of semantic occurrences before
pointer machine normalization. Parameter ordinals, lexical bindings,
assignment, branch alternatives, direct-call argument/result uses and function
results refer to that graph. Pointer casts, pointer/integer conversions, null
construction and offsets remain visible even when they emit no instruction.
Function and call identities come from the existing lowering symbol authority;
source spans use the existing source-location authority. The graph records
resolved `Ptr`, `MutPtr`, integer and other source categories independently of
the scalar machine representation.

`lower-compiler-pointer-proof-result` produces the typed
`ResultCompilerLowerPointerProof` analysis handoff only for complete evidence
coupled to the exact unoptimized program and its source-span table. Ordinary
lowering, a reused job owner, a foreign program, missing function metadata and
an unclassified pointer producer fail closed. Consumers analyze this handoff
before mutating or optimizing its IR; a later IR result cannot substitute for
it. This layer
does not grant nullable ABI permission or admit a return: caller/static origin
classification, joins, recursion and witnesses belong to the return analysis.

The graph owns copied source paths, spans and source categories in a dedicated
arena, with no borrowed AST nodes, pooled types or source-interner strings.
Its caller-owned control cell must remain live throughout analysis. After the
handoff is consumed, `pointer-proof-input-release!` tombstones that cell and
retires its data arena; references from another owner or a retired owner are
rejected. Each job requests a fresh owner; a failed requested source job also
consumes its owner. Disabled jobs allocate no graph and
perform no additional expression traversal.

Compilation is one whole program per executable with import-graph dedup
(each module typechecked once per program). Package dependencies are
codegen'd once into archives; an in-process session cache warms compiler
pools across compiles within one process (batch and LSP paths).

The serial in-memory LSP transport keeps its arena handle, input snapshot,
cursor, EOF flag and captured output in one `LspFrameMemoryState`
(`src/lsp_frame_core.tl`). Install and reset replace the whole value; only the
cursor, EOF flag and output fields change in place. The transcript runner copies
captured output into its caller's arena, saves the transport handle, resets the
state, then destroys the session and transport arenas, so no transport field
stays globally reachable after its owner is gone. The LSP frame smoke covers
reset and reinstall after the input was consumed and both outputs written.

Each function body typechecks against a function-local fork of the module
environment (#8375): `tc-type-env-fork-function-store` creates a store in the
function's rewound scratch with the parent's head and capabilities, and the
fork's binding and cache segments grow there. Environment heads are raw node
addresses, so the fork's records link to the parent's immutable nodes without
copying them, and the parent store never receives a function-local record. The
parent's explicit-layer chain index stays shared read-only until the fork's
first layer registration, when `tc-chain-state-ensure!` copies it into the
scratch. Only the parent environment reaches lowering. Retiring the scratch advances `tc-type-env-store-epoch`, so memos keyed
by a store handle or node address cannot match a later fork reallocated at the
same address, and clears the unbound-name suggestion snapshot that names the
fork.

Checked semantic consumers use `compiler_semantic_lint_facts.CompilerSemanticCheckRequest`
for a source, file, or package entry. The request carries the existing job,
cfgs and roots, a caller-owned facts arena, and a borrowed consumer callback.
`checked-generated-source` is the caller's assertion that the physical input is
a checked-in generated file; generated declarations and expression expansions
remain synthetic. The collector supplies `compiler_check_core.CompilerObservedCheckRequest`, which
runs the canonical checked-program pipeline once and invokes publication before
checker pools retire. The ordinary CLI does not import the collector module.
The observer belongs to the shared context, separately from the hot body-analysis
descriptor. Context rebuilds carry it explicitly, including a suppressed probe.
It is installed only in the final checked context, and is removed before checker
state or facts storage can be retired. Macro probes and discarded
speculative checks cannot publish observations. A disabled observer allocates no
snapshot, walks no additional AST, and does not extend body-fact lifetimes.
A balanced count of observed jobs lets disabled hooks skip observer state reads.
Nested jobs preserve that count; their own context still selects the observer. Binding
token capture samples its parse-control option at the existing capture boundary
and saves/restores it with that scope, so disabled token hooks inspect no dispatch
views or source tokens.

`compiler_semantic_lint_facts.CompilerSemanticFacts` is a read-only capability.
Count and lookup operations return owned records in the consumer's active arena;
the capability itself is valid only until its request's facts arena is destroyed.
Consumers finish the callback, destroy that arena before the next entry, and use
the host driver's normal file-job cleanup for checker, pool and interner owners.
The owned driver scope is exercised by the batch lifetime test. The check result
contains diagnostics and advisories, never a facts or checker capability.

Expression IDs, function indexes, declaration ordinals and lexical scope IDs are
local to one snapshot. Persistent consumers derive anchors from owned module,
name, path and declaring-token spans rather than retaining those ordinals or a
`TcTypeEnv`. Shared resolver hooks publish the selected lookup key or member
handle, including definition-site macro hygiene. Scoped bindings retain their
per-job stack epoch, slot and generation together, so temporary SPMD imports cannot overwrite
an active slot version and recycled slots cannot identify an older local. Declaring
spans come from opt-in parser tokens and the checked initializer's source span;
checker markers and imported captured bindings do not create declarations.
Let scopes use their body IDs, which survive by-value SPMD rechecks. Rechecking a
source body for SPMD reuses its source-function identity. `try` compatibility
uses `tc-try-query`; foreach and SPMD bodies forbid early exit, while a nested
lambda establishes a new return owner. Observed SPMD classification calls keep
that policy scope around by-value operand rechecks, including let initializers;
the scope is tied to its function owner and closes on both success and error.

Source and exact macro-argument provenance can authorize edits only when the
expression also has a reliable result and a complete source span. Unknown,
synthetic, unresolved, poisoned and dependent facts fail closed. A failed check
after observing poison is dependent rather than a new unresolved primary error. An imported
generated nominal may have an owned declaration identity without an editable
defining-token span. The snapshot retains no pooled types, intern spellings,
parser sidecars or mutable checker environments. Lint policy and command/LSP
adoption are separate consumers of this interface.

File, package, check, test and semantic-index entry points pass their actual cfg
environment through the lowerer/typecheck interfaces; a cache-scope String is
only an identity key and cannot replace those semantic inputs.
Declaration-producing macro expansion threads that environment through scratch
generations and reparses both `Decls` and `Module` output with that same
environment. Generated predicates use the canonical parser evaluator;
constructing an empty dispatch would silently drop enabled declarations. Syntax
head classification does not evaluate predicates and may use the cfg-free
keyword table. The lowerer's closed core-macro Clone handoff supplies its explicit
empty source-language cfg set. The `generated_cfg` native fixture and interleaved
cfg driver-state smoke guard this boundary.

The expansion walk splices each macro's output into a segmented program view
and continues over it. A splice costs work in its delta and the module it
expands in, never a rescan of the whole program (#8120). Segment nodes and the
emitted prefix index their module-marker and import rows, so a module's local
environment and the import-alias index read those rows plus the target
module's own rows. Each cached top-env layer records the resolution generation
at which it last re-resolved its unresolved signatures. Only a new walk, a
splice with a nominal type, import or module row, an import marker, or a lazy
import stub advances the generation, so function-only splices skip the pass. A
splice that keeps the context's flat program keeps its module declaration
index. The `macro-segmented-program-events` test and the generated-declaration
typecheck cases cover the event index and the re-resolution boundary; the
`expansions` compiler-scaling row measures expansions within one module.

Lexer tokens are scan scratch. Their geometric growth replaces dedicated
storage after moving the live prefix, then retires the superseded owner and
restores the caller's active arena. Token storage is not published until
scanning returns. Token literal payloads remain in their source/interner
owners, so growth preserves records and indices without retaining all previous
capacities. The spanned reader pool is the only s-expression tree; plain data
reads (lockfiles, TLCI metadata) use its `data-result` mode. It also owns
declaration/member origins. Rows live in fixed 1024-row segments that never
move or get freed while the pool is live, so a borrowed view of a list's
children stays valid while the parser and the macro expander keep pushing rows.
A list never straddles a segment (the rows it skips hold an inert filler), and
a list longer than a segment gets one dedicated array. Truncated long-list
storage reuses a sufficiently large array found in its covered directory slots,
restoring fragmented mappings. Long arrays grow geometrically, keeping both
repeated and increasing forms' storage bounded. The load handoff copies
the live prefix into an exclusive owner, in whole segments, without changing
row ids; a handoff is the only point where rows move. Subsequent growth appends
segments to that owner. Reset revokes exclusive ownership before another load
session can share the reader arena; pre-handoff growth must preserve that
shared arena. The final handoff compacts the prefix again after lowering. The
compile-profile verifier checks retained arena bytes before that compaction,
and `src/tests/scan_storage_growth.tl` covers retained growth in place, the
handoff's owner retirement, failed reads and shared-session reuse. Whole-load scan release empties the
token scratch, while reusable sessions retain their current capacity.

The IR source-span table (`CompilerSourceSpans`) keeps two dense lists of flat
inline records: function entries (symbol, path id, span; 32 bytes) and
instruction entries (value, store or bounds key, path id, span; 48 bytes). The
records carry no variant tag, so a slot costs exactly its fields. An append with
spare capacity writes the shared slot and growth copies the live prefix;
escaping a table copies only that prefix into the current arena, which leaves
no pointer into the arena that built it.

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

Every example is its own program.
- **Runnable examples** compile after a full driver file-state reset.
- **Check-only examples** reset the interner to the session floor first (`compiler-check-reset-interns!`, as lint does per file). So nothing an earlier example or file interned or generated reaches them. The session's program cache survives, so examples still share loaded dependencies.

A batched run therefore gives each file the result it gets alone (#8580). `scripts/verify-doc-tests.sh` fails a batched run that fails while every file passes alone; its per-file probe only locates failures.

The lifetime tests in
[`compiler_package_discovery_lifetime_tests.tl`](../src/tests/compiler_package_discovery_lifetime_tests.tl)
exercise arena reuse, path and diagnostic ownership, session restoration,
subsequent checking, target changes, cfg snapshots, admitted native mappings,
and runnable/failure metadata. Ordinary
`clone` is not a valid way to escape flat-node compiler ASTs: their pool-backed
payloads require the loader's pool-aware compaction or an explicitly owned
pool lifetime.

Every source file a load session consumes is read through the session's source
provider (`compiler-load-session-state-read-source-text`), which normally reads
the file. An overlay check (`compiler-check-file-with-overlay`,
`compiler-check-package-entry-file-with-overlay`) installs one admitted
[`compiler_source_overlay`](../src/compiler_source_overlay.tl) generation on the
serial session for the duration of the check. Imports and packages resolve
exactly as before; only an admitted resolved path is then answered from the
overlay's bytes. Overlays replace `.tl` sources outside every stdlib root, never
manifests, so they cannot change which file an import names. While a provider is
active the program caches are bypassed, and every consumed source (disk,
embedded stdlib or overlay) is recorded once, in first-read order, in a ledger
allocated in the caller's arena, together with the other disk inputs that decide
what the check sees (manifests, a dependency's TLCI image). A source read twice
with different bytes or a ledger over its limit rejects the check, and so does
an admitted source a passing check never read. Re-reading the ledger's disk entries (`compiler-source-ledger-stale-paths`)
lets a caller that later writes files detect inputs that changed in between.

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
by surface identity order. Exact package-root lint detects uncalled producer
declarations, while embedded-stdlib and package-surface parity gates exercise
the real producer entries.

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

Inline-test harness construction prunes runtime declarations before typechecking.
An unresolved dotted name may be an imported member or a projection from global
storage, so reachability retains both the final member and the first source
component. The normal fixed point then retains a referenced global's initializer
dependencies. Hygiene and module qualification are normalized against the captured
intern session; dotted projections must not consult another installed pool.
Unrelated globals remain pruned. The global-field inline fixture and harness
retention test guard this boundary.

A global's IR initializer takes one of three forms:
- **A constant value**, emitted as static data.
- **`RuntimeGlobal`**, naming the hidden `__global_init_*` function that the
  entry code calls before `main`.
- **`StaticArray`**, the exact little-endian element bytes of a fixed array of
  constant scalars (#8369).
  - It appears only as a global initializer. The optimizer copies only `I64`
    initializers into instructions, and the backend's operand load rejects a
    `StaticArray`.
  - The backend emits one writable copy per global behind the cell and never
    deduplicates them, so the cell keeps the pointer representation of every
    `(Array T N)` value.
  - The direct-object encoder has no static-array record, so such programs
    take the assembly path.

Mutable typecheck caches, indexes and traversal state belong to the compiler
job's `TcJobState`, never to process-wide cells, so resetting or destroying one
job cannot disturb another. A value that is a pure function of intern ids is
not cached at all: a stdlib comptime syntax type is recognised by decomposing
the structural module key of its canonical id, and comptime helper prefixes are
compared with the builtin ids directly. Generation-stamped mirrors of such
values only add state that must then be reset and isolated. The families that
still await migration are tracked in #4960.

Each compile and each `compile --batch` entry resets the interner. Those resets
cost what the compile used, not the tables' capacity (#8520).
- **Hash maps.** The source and generated maps log every slot an insert fills.
  The log travels with the map arrays: a state owns it, and it is installed and
  captured with them. So `intern-compat-state-reset!`, `reset-to!` and the
  installed-global resets empty only the logged slots.
- **Fallback.** Past an eighth of a map's capacity the log saturates, and that
  reset clears the whole map.
- **Why a log.** An id range cannot stand in for it, because the state path and
  the installed globals keep separate source cursors.
- **Structural table.** Its reset clears by record in the same way.

The move checker stores an ordinary cleanup-owning `let`'s obligation in its
lexical locals entry and its discharge in the existing place-path facts.
Private owner-count and loop-depth entries use reserved negative map keys;
source and structural name identities are nonnegative, so these snapshots
neither alias bindings nor depend on an installed intern pool.
Owner metadata preserves exact loop depth across the expression pool's range,
so an inner loop exit cannot require discharge of an outer loop's owner.
Shadowing snapshots and restores the outer binding's facts. Normal exit edges
check every owner they leave before diverging arms are removed from joins;
normally completing paths must agree on obligated roots. Transfer through a
value form proves that every normal result names the same visible owner,
using that job's original expression IDs and recorded divergence facts.
`never` paths have no normal cleanup edge.
Lambda bodies start from their capture locals so their exits cannot discharge
or require the enclosing function's obligations or inherit its loop depth.

`AstType.Invalidate` retains a parameter's lifetime destruction effect through
callable identity, substitution, reflection and surface serialization (schema
12, type tag 39). Parameter binding exposes the inner type while a lexical
marker records the enclosing callable's effects. Its obligations reuse the
existing per-exit engine, but only canonical safe destruction or forwarding to
another effectful parameter discharges them; ordinary ownership transfer does
not. Calls substitute all effect lifetimes before applying the existing arena
move, borrow, active-target and atomic-user checks. Lowering erases the wrapper
from physical parameters without changing their ABI.

The comptime evaluator has no import scope. Before a source `(comptime ...)`
fold or a fixed `make-array` length is evaluated, typechecking and lowering
resolve each type literal of the expression in the current module
(`tc-ctfe-env-for-comptime`) and pass the resolutions with that one evaluation's
environment. Layout and reflection queries therefore see the declaration an
annotation would name, not the spelling: `(type other.Point)` through an import
alias reaches the layout of its defining module's `Point` (#8112).


An array allocation (`make-array`, `__tl_make-array`) whose element default
is all-zero bytes lowers to `tl_array_zero`. That runtime fill skips memory
the arena has never handed out. Other defaults lower to a per-element init
loop. `lower-make-array-zero-fill-supported?` decides which applies:
- scalars and raw pointers;
- default-layout structs whose fields all qualify;
- enums whose tag-0 variant's payload fields all qualify, including a
  fieldless tag-0 variant (#8520).

Types outside that list, such as `String` and `Box`, keep the loop. A `Box`
default, for one, is a live allocation.

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

Copy environments use a dense `OptCopyEntry` array, a snapshot length and
an arena-allocated lineage top cell. Slots beneath every retained snapshot
remain immutable. Push appends at the current top with spare capacity; extending
an older snapshot copies its live prefix. Growth shallow-copies compiler arena
values using their inline layout size. Zeroed empty snapshots skip their null
top until allocating storage. Truncate clamps its mark and declares every
longer snapshot dead; only consumed block-local clears use it. Invalidation
first checks for a retired destination/source, returns unchanged snapshots when
none exists, and otherwise copies retained facts in order. Lookups stay newest
first and preserve local IDs, negative global keys and pack-word keys. The copy
environment smoke covers growth, wide entries, forks, zeroed storage, clears,
source invalidation and retained snapshots.

LICM moves a load only with evidence that its word is readable at the
preheader. The strongest is that the loop reads it on every entry anyway: in
the header, or a block the header's chain of unconditional jumps enters, before
any instruction that may abort or not return. Otherwise an element read needs
`i <u len` proven there, and any other read must be a fixed word of a trusted
root, inside the root's extent. Roots are parameters, globals, call results,
checked loads and string literals of checked pointer types, frame objects
(their `alloc` run), and var homes (their value's representation, so a register
group's pair). Copies and phis pass roots through; phis are joined by an
optimistic fixpoint. Raw pointers, integers, casts, pointer arithmetic and
joins with a literal arm are never evidence. An enum pointer spans only its tag
word, because a nullary variant is an 8-byte tag global. Global extents and
value representations are captured at program entry, before inlining, so the
priced and final pipelines see the same roots. A block holding an
always-failing literal bounds check hoists nothing. The `licm-deref` optimizer
test and `tests/integration/licm_raw_deref.tl` guard these rules; #8124 tracks
a checked pointer loaded speculatively from an enum payload.

An element read refused only for want of that bound can still leave a counting
loop whose one exit is the latch's, behind the bound its own check tests. When
a `bounds_check i, len` (or the unsigned test whose edge leads there) comes
before the read, with `i`, `len` and the address all available at the
preheader, the preheader branches on `lt i, len : u64` to a block that does the
read, and a join takes the loaded word or a zero. The loop keeps its check,
which dominates every use of the value and tests the same two values, so the
zero never reaches a use and no unbounded address is read. Reads of checked
pointer types, reads wider than a word or than one element, and reads reached
only through an equality's equal edge are left in place. One LICM run below the
level-2 fixpoint and every loop-cloning pass places these guards and moves
nothing else. It analyses only loops where a block checks an invariant index
and then reads an invariant address, which a syntactic scan finds first, and
it records one plan per read during the loop walk and builds the diamonds
afterwards, so no loop's body or dominator facts change under the walk. The `licm-guard` optimizer test and `tests/integration/licm_guarded_read.tl`
cover it.

The multi-block bounds-check versioner clones a loop behind one entry guard
and drops the checks the guard proves. Its derivations read a counter's value
range `[seed, bound)`. A top-tested loop's counter may be a monotone cursor:
its latch value merges `j` and `j + 1`, as in a scanner that stops instead of
stepping. The cursor still lies in that range on every trip the test lets
through, so it is recovered as an inexact counter. Rules that count latch
crossings (derived inductions, phis that share the seed) stay off for it. A
cursor loop versions only when the clone keeps no check and some check reads
the cursor. Otherwise the loop is offered to the counter-free shape as before;
a hash probe's `walked` cursor is that case. The
`bce-version-mb-monotone-cursor` optimizer test and
`tests/integration/bce_monotone_cursor.tl` cover it.

Call-memory root scanning, summary accumulation and write predicates read the
live prefix of dense block sequences directly through the block sequence accessor.
These internal shallow reads require valid storage and an index below logical len.
The instruction helpers remain authoritative for effects and provenance. Root
updates retain forward order and both existing passes; unresolved candidates and
successful predicates stop before reading later blocks. No scanner mutates block
storage or consumes spare capacity. The `call-memory-dense-scan` test covers
delayed definitions, unstable bindings and early exits.

Affine folding keeps one mutable fact table per function: local vreg IDs index
compact binding slots, and only live bindings are scanned for key/base
invalidation. Every block starts with empty facts; the cumulative 512-binding
budget also clears facts without freeing or replacing their backing storage.
Invalidation does not refund that budget. No caller retains an older environment
snapshot, and the table dies before the function's optimizer arena is rewound.
The affine storage reference/growth tests and optimizer smoke driver protect
these rules. Reuse the existing generated core vectors for compact payloads;
do not allocate wide records for every possible local ID or rebuild cons chains.

Block-local CSE (`opt-cse-instr`) and the Slice-word CSE in the load/copy walk
reuse one table pair per function pass (`OptExprTable`), clearing each table
before its block walk. The block walkers borrow the pair mutably. An empty
carrier allocates storage only on its first insertion, and that walk stores the
state back into the pass's pair, so every later block clears and reuses it with
its capacity. Keys keep stable positions;
parallel integer storage records results, live entries and collision links.
Power-of-two bucket heads index expression hashes, and lookup checks structural
equality within the chain.
The index grows at half occupancy by relinking live positions. Lookup treats
zero or one live entry directly; hashing starts with the second
live key, so this constant-size path never scans a growing table. Once started,
the index remains active until clear. Invalidation unlinks indexed dead entries
and compacts only live positions. Calls, stores, shuffles
and control-flow boundaries clear lengths and advance the bucket generation,
retaining capacity without scanning it; generation rollover resets all stamps.
Entries are added only after a lookup miss, so live keys are unique. No caller
retains an older table or a view across vector growth.

Aggregate scalar replacement tracks each eight-byte word as either one scalar
or disjoint, naturally aligned integer/bool lanes. Every access to a lane must
agree on its type. Whole-word accesses and copies covering a lane word refuse
the candidate, because padding bytes have no scalar representation. Refused
candidates never index the fixed-size word table. The aggregate-split tests
cover lane folding, overlapping accesses and copies across lane words.

Register-group splitting also accepts a single-definition phi when every input
is a variable and every use extracts a word. It emits scalar definitions in
the predecessor blocks and lets SSA repair join them. An input pack may supply
its operands directly only when those operands are literals or have one
definition; otherwise the edge extracts the original group value. Escaping
group joins retain their aggregate representation.

The multiblock inliner admits known one-word nominal results and register groups
within the group splitter's word limit, using the installed program
representation index. Unknown representations stay out of line. CFG cleanup
may merge a split loop test or a straight scalar loop chain while preserving
phi predecessor keys; those loop-shape merges stay disabled in the inliner's
priced pipeline. The range-loop integration and assembly cases check the
resulting code and preserve located bounds failures.

The level-2 inline stage rewrites each caller inside one phase of a scratch
arena and keeps only the caller's final body, cloned through the job's explicit
pools, and the span rows its rewrite added; the phase is rewound before the
next caller. Tables a rewrite leaves for later callers grow in the IR label
arena, have fixed capacity, or hold scalars, and the per-walk caller views are
unpublished before each rewind, so nothing that outlives a caller points into
its phase.

That final-body clone writes into the optimize call's optimizer-input arena
(`OptOptimizerInput`), not the stage arena, and records the body's symbol id.
Every slot is placed, rewritten or not. The input the per-function loop reads is
the pruned survivors, taken from that arena. A survivor with no recorded
placement is copied there. So the inline arena is released before the loop with
no body the loop reads, and no second whole-program copy overlaps it. Level 1
has no input arena and reads the tiny-leaf stage's arena in place.

The checked inliner's literal-argument scan borrows dense block storage directly.
It visits blocks and instructions in forward order without building
copies. Its result includes every matching definition and the last integer
literal, even after a duplicate makes specialization ineligible. Keep traversal
separate from that admission decision; stopping the scan early changes its
recorded result. This read-only path does not change block ownership.

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
Avoid unconditional arenas for small analyses: an arena per analysis
multiplies arena creation and regresses ordinary compile time.
Stack coloring keeps physical frame slots separate from the final logical
variable extent. Wide homes can move IDs above the original plan count, while
register-only IDs can remain above the compacted frame. Final liveness, type and
home tables, use facts and scavenger contexts cover the maximum of both domains;
frame layout continues to use only the physical slot count.
Final scavenger intervals still describe the
final emitted IR at instruction precision. Call-hole retry context retains its
edge-precise liveness while candidate rewrites still consume it. These lifetimes
bound overlapping analyses within a large function; the existing function and
assembly-stream arenas continue to bound accumulation across functions.

Optimizer substitutions must prove their per-variable definition requirements;
late IR may still contain mutable locals when SSA construction declines a
function. `opt-def-counts-*` counts entry parameters and all destinations through
the verifier's canonical instruction classifier.

A local whose address is taken (`addr_of v` anywhere in the function) is
memory, not a value: a store or call through the exposed address redefines it
without naming it. No pass that forwards values by definition records a copy or
constant fact naming such a var, as destination or source.
- Global copy/CSE and affine folding read the marks of `opt-addr-taken-vars`.
- LICM and the block-local `fold` pipeline read the installed per-function set
  `opt-function-addr-taken`. Each installs it before rewriting a function:
  LICM once it has found a loop, and `optimize-block-list-for-function-pass`
  before its block walk. `fold` keeps it out of its constant environments and
  its copy environment (#7973).
- One scan builds both, and allocates nothing for a function without an
  `addr_of`. The loop call cache keeps a separate scan.

#8190 tracks making this one pass-wide rule with an adversarial matrix.

The compiler also has a pure, versioned incremental-query identity layer. It
canonicalizes typed source, logical-name, dependency, package/stdlib,
configuration, macro/comptime, target, and ordered-child inputs into a bounded
binary transcript and exact SHA-256 fingerprint. The layer is relocatable and
independent of cache storage: callers supply authority-checked package-relative
paths and nominal compiler/child identities, while event capture, invalidation,
result serialization, and reuse policy remain separate compiler services.

[`compiler_incremental_graph.tl`](../src/compiler_incremental_graph.tl) holds a
previous run's successful queries as one immutable graph (#7322).
- **Nodes.** A node joins:
  - a query identity;
  - the semantic output identity its parents observed;
  - the opaque key of its stored result, which is never compared with an output;
  - its complete committed trace.

  Child-result edges resolve by exact query transcript and must match the
  child's published output.
- **Roots** are typed purpose/name pairs.
- **One parser.** Finalize encodes the sorted candidate and decodes it with the
  same strict parser that admits persisted bytes. So a published graph has
  passed framing, budgets, canonical order, referential integrity, reachability
  from a root and acyclicity, and a failure publishes nothing.
- **Validation memory.** The transient identity and trace decodes run in one
  scratch arena per decode.
- **Exposed.** The graph exposes deterministic lookup, dependency and dependent
  rows, a dependencies-first order that releases the smallest canonical index
  first, the canonical bytes, and their SHA-256 fingerprint.
- **Out of scope.** Payloads, the result store and replanning stay with their
  owners (#7187, #7023, #7188).

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

Before that, the output is spelled back as syntax for the declaration parser.
A quasiquote template's expression positions hold parsed AST nodes, so
`macro-expr-to-spanned-sexpr` converts each node to the form the parser reads.
That includes the scoped arena, scratch, escape and `with` forms, loop
control, `comptime`, lambdas, `foreach` and the SPMD forms. Its match has no
fallback arm, so a new `AstExpr` variant does not compile until it is given a
spelling. The `macro-output-expression-forms-round-trip` test checks that every
form converts to exactly the syntax it was written as and re-parses to the same
kind of node. `tests/integration/decls_macro_scoped_forms.tl` runs the CTFE
route. `scripts/verify-package-native-tlci.sh` runs the native dependency route,
which splices a consumer's `in-arena` body into a Decls macro's output.
Native transformers cannot yet build these forms from their own templates and
fall back to CTFE for them (#8547).

Write authority over globals (SPEC §4.4.2) is enforced in the move checker's
write arms, so other nodes pay nothing. Each write-capable arm of
`tc-move-check-expr` (plain and dotted `set!`, field/tuple/element/`deref`
writes, `replace!`, the private dynamic-array push/take, and
mutable `Borrow`) calls `tc-move-foreign-global-place-check` or
`tc-move-foreign-global-set-check` before its own rules. The check resolves the
projection root through the same symbol-handle path as the global-move rule and
compares the declaration's owner module with the module being checked. Expanded
macro code sits in the caller's body, so it is checked as the caller's module.
A new write-capable place form needs the same call in its arm. Alias-qualified
`set!` targets never bind in the value environment and are diagnosed while
typing (`tc-set-foreign-qualified-global-message`). The
`tests/safety/foreign_global_*` fixtures pin every route and import spelling.

Function declarations are not storage places. The ordinary `set!` typing path
uses the existing source-name and symbol-handle resolvers to reject function
`define` and function `extern` targets before typing the replacement. Scoped
and persistent lexical bindings retain precedence, including function-valued
locals that shadow imported declarations; hygienic definition-site references
retain the declaration's identity. `tests/safety/function_set_*_reject.tl` and
`function_storage_assignment.tl` cover these distinctions.

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
assume declaration generators have finished. The load-time walkers follow the
same rule from the other side: a selected item that is missing from a module
whose parsed declarations still contain a module-scope generator
(`compiler-load-module-has-pending-generator?`) is deferred rather than
rejected, and each macro-expansion pass skips binding such a selection until a
later pass has produced it. A module without generators has its final
declarations at load time, so its missing items keep failing immediately. Errors use the marker's physical
path and span. Each scan uses temporary maps that are not cached; composite-key
interning is published to the job's intern owner before handoff. The generated
import runtime fixtures and interleaved loader-state smoke guard these contracts.

Handwritten runtime, startup, and direct-object x86-64 code is covered by the
closed [compiler-owned executable template registry](../docs/compiler-x64-executable-templates.md).
It records mutation-sensitive source identities and typed control/frame events
for later native-code certification.

Structured object branches reuse flags only from the immediately preceding
integer comparison in the same IR block, when that comparison defines the
branch operand. Its `setcc`, zero extension and frame store preserve flags;
floating comparisons and intervening instructions invalidate this fact.
Fallthrough uses the next block in emission order. The absent-next-block
sentinel cannot match a branch target; an
invalid target must remain an unresolved edge for the serializer to reject.
Phi copies remain edge-specific: a conditional jump selects the
false copies, and the true copies must jump past them before entering their
successor. `Jcc` accepts only x86 condition codes 0–15. Its six-byte encoding
places the rel32 field at byte 2; ELF, COFF and native TLCI relocation use that
same site. The object branch tests check all conditions, forward/backward
targets, invalid codes and unresolved symbols across these serializers.

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
Transformer source is appended in catalog order to a geometric byte builder;
rendering an entry must not copy the already completed catalog prefix.
Later TLCI finishing reads only the captured text/catalog and checked surface;
it must not revisit source declarations or dereference source intern IDs.
The native producer's capture-based adapter and
`embedded-native-emit-package-source` share one native compilation and image
emission implementation. Runtime diagnostics and checked-surface failures still
precede deferred export metadata errors. The export lifetime tests destroy and
reuse the original parser/interner storage before emitting both target images.

`build-package-prepare-owned-runtime` in `build_cli_core.tl` selects the
package route from one `BuildPackageDirectObjectRequest`: target, artifact kind,
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

The common `ar` byte-container boundary lives in `src/linker_archive_core.tl`
(#7392). `scan` accepts immutable arbitrary-byte `str`, caller-assigned input
and content/revision tokens, an explicit profile, and explicit limits. The
profile selects each numeric field's decimal/octal grammar, blank policy and
maximum, raw-name ASCII policy, exact sixteen-byte special-name patterns, and
whether an odd final payload may omit its pad. Size is always nonblank decimal.
No path, extension, host locale, decoded name or object symbol selects policy.
The fixed signature/header/padding layout follows the [PE/COFF archive format](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format#archive-library-file-format).

The scanner validates the complete input before allocating an exact-size
physical directory. A second bounded header pass fills descriptors containing
raw names, classification and payload spans; neither pass reads or copies
payload bytes. Subtraction-based range checks precede offset additions, and
numeric maxima are checked before multiply/add. `ArchiveMemberId` combines
input/content identity, physical ordinal and header offset, so duplicate names
remain distinct. The caller must not reuse a content token for changed bytes or
a profile tag for changed policy, and must retain the scanned directory
unchanged. Public record constructors are not a capability-security boundary.

A separate `ArchiveSession` owns claim bits and operation budgets. `open!`
validates all ID components before indexing: the first request returns the ID
and exact borrowed payload, subsequent requests return `AlreadyOpened` with
that ID. Payload lifetimes follow the input, so they survive later session
operations. `map-index!` is the dialect hook: a bounded binary search maps an
adapter-decoded offset only to an existing header and can reject special
members. Failed index requests consume their attempt/work budget. This layer
never caches parsed objects or chooses symbols; those decisions belong to
#7099. The GNU/BSD and Microsoft adapters (#7038, #7244) own name/index decoding,
special-payload validation and dispatch. Thin archives, nested interpretation,
filesystem lookup and mutation are not provided here.

Limits bound input/output bytes, member count, retained descriptor/name/claim
storage, special members, index attempts, diagnostic rows and work. Retained
storage charges `sizeof(ArchiveMember) + sizeof(bool) + 16` per member, with
names inline and input bytes borrowed. The extra sixteen bytes reserve the
current runtime payload-view record; header comparisons create no views. A scan returns at most one fixed-size error
carrying kind, input/content identity, ordinal and byte offset; at least one
diagnostic row must be available. Ordinal -1 identifies archive/profile errors.
Work is a conservative byte-visit/comparison budget rather than CPU time:
13 base units plus 17 per profile pattern, then 137 plus 32 per pattern for each
member's validation/fill passes. Session initialization charges one unit per
claim slot; opens charge one and index attempts charge one plus each search
comparison. Consumers use one session per archive input for load-once behavior;
creating another session deliberately starts an independent consumer budget.
All checks precede variable-size allocations, and no allocation scales with
payload size during scanning or opening.

`src/linker_archive_output.tl` borrows a native Slice of encoder plans whose
payload strings remain owned by the caller. It preflights the whole layout,
field widths, limits and work before allocating output, then writes canonical
left-justified numeric fields, the terminator, opaque payloads and newline pads.
Metadata -1 requests an allowed blank; all other metadata is nonnegative.
Writers supply names, metadata, special members and physical/index order; the
container never synthesizes dialect indexes. Its byte buffer copies payloads
directly into output, with no intermediate payload String copy. Encoding
charges 120 units plus 16 per pattern per member, and three per output byte
for initialization, writes and final String conversion. `dump` shares session
work and diagnostic limits, emits a 42-byte identity row plus one 103-byte
physical-member row, and charges three units per byte. Fixed-width hexadecimal
IDs, spans and raw names make dumps independent of locale and path spelling.
`linker_archive_core_tests.tl` covers byte goldens, every truncation boundary,
limits, forged/stale IDs, borrowed addresses and a fixed mutation corpus; its
same assertion body runs on both hosts in the native integration manifest and
in inline tests.

AMD64 import-library member encoding lives separately in
`src/linker_coff_import_member_writer.tl`. Its caller supplies a validated DLL
basename/stem pair and ordered, explicit import plans. The encoder validates
the four documented name modes, symbol uniqueness, and configurable work and
output bounds before allocating the result vector. It returns three fixed COFF
support objects followed by one short import object per plan; each member owns
its payload and ordered archive-index symbols. The archive/index layer consumes
these records without deriving names from payload bytes or changing their order.
The encoder does not select exports from package declarations or publish an
archive. Its inline oracle test compares all seven payloads in a maintained
LLVM AMD64 fixture, including the empty-export support objects.

Embedded link policy is read by `src/linker_coff_directive_reader.tl`. The
object reader passes a section header summary (object identity, section
number, name, characteristics, relocation and line-number counts) and the
bounds of the section data in the object bytes. The reader admits only a
`.drectve` section with `IMAGE_SCN_LNK_INFO` and no relocations or line numbers.
It tokenizes whitespace-separated options whose payloads may contain quoted
segments. Quote bytes are dropped. A backslash before a quote, adjacent quotes,
quotes in an option name, and NUL are rejected, as is non-ASCII text without a
UTF-8 BOM, because a host ANSI code page is never consulted. With a BOM, every
token must be strict UTF-8. The only admitted options are `/DEFAULTLIB`,
`/NODEFAULTLIB`, `/INCLUDE`, `/EXPORT`, `/ALTERNATENAME`, `/FAILIFMISMATCH`,
`/DELAYLOAD` (file name only), `/DELAY:UNLOAD` and `/DELAY:NOBIND`, matched
ASCII case-insensitively. Each becomes an ordered typed record carrying its
exact byte range and written spelling. Any other option, including response
files and output, search-path, section-layout and security directives, fails
closed with the object, section, byte range and admitted alternatives. Byte,
option and token counts are bounded by caller limits. Reading is pure: default
library order and suppression, forced roots, aliases and mismatch keys belong
to #7102, exports to #7125, delay loads to #7094, and the external-link
preflight to #7423. Directive text is never forwarded to another tool.

Linux profiles ship some `lib*.so` link inputs as tiny GNU ld scripts; glibc's
`libc.so` is `OUTPUT_FORMAT` plus a `GROUP` with a nested `AS_NEEDED`.
`src/linker_script_subset.tl` reads only that implicit subset: `OUTPUT_FORMAT`
(one or three names), `INPUT`, `GROUP`, `AS_NEEDED` nested to a depth limit,
`SEARCH_DIR`, `/* */` comments, quoted names and `-lNAME`. It produces the
commands in order with line and column, and every `INPUT`/`GROUP` file in one
ordered list that the commands index. Anything else is refused by name rather
than partly executed: `SECTIONS`, `INCLUDE`, `INSERT`, `MEMORY`, `PHDRS`,
`PROVIDE` and other GNU commands, assignments, expressions, unknown words,
unbalanced parentheses, unterminated comments or quotes, NUL, control bytes,
and non-ASCII outside quotes. Byte, token, token-length and nesting counts are
bounded by caller limits. Reading is pure; resolving the names against profile
roots and recording them in the link manifest belongs to #8304. The fixtures
under `tests/fixtures/linker-scripts/` are real installed scripts with their
provenance.

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

Required verification is one table,
[`scripts/ci-gates.tsv`](../scripts/ci-gates.tsv), run by `scripts/ci-verify.sh`.
The [scripts README](../scripts/README.md#core-development-loop) describes the
table and the gates; read it before changing CI structure.

## CLI

`typelisp --help` lists the commands and the global and common options;
`typelisp <command> --help` shows each command's options.

Common options include `--target linux-x86_64|windows-x86_64` (Linux is the
default output target; `test` defaults to the host), `--backend-mode
scalar|avx2|avx512`, `--opt-level 0|1|2` (0: no IR optimizer; 1: cheap
stack-only passes; 2: full optimizer with register allocation and inlining —
levels never change program semantics), `--manifest-path <file>`,
`--stdlib-root <dir>`, `--locked`, `--update-lock`, and `--cfg <name>`. The
REPL remembers top-level declarations and evaluates bare expressions by
compiling a scratch program through the real build/run pipeline — there is no
interpreter. `.load <file>` adds a source file's declarations to the current
session after checking the combined session. Scalar results are printed
directly; structs, enums, tuples, and fixed arrays use the stable fallback
`<value: Type>` because TypeLisp does not currently provide runtime reflection
for their contents.

Human-facing `check`, `compile`, `build`, `run`, and test-preflight failures
render error codes, source locations and snippets, carets, secondary labels,
and available help/notes. LSP and other machine consumers keep their structured
or stable flat diagnostic representations. Diagnostic codes are append-only:
published numbers are never renumbered or reused. Run `typelisp explain <code>`
for a description, minimal failing example, suggested fix, and related
references. Code lookup is ASCII case-insensitive. `typelisp explain --list`
prints the registry and `typelisp explain --search <term>` searches its titles
and prose. The code list, with owners and construction sites, is in
[diagnostic-codes.md](../docs/diagnostic-codes.md).

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
