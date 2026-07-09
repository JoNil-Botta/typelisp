# TypeLisp Stdlib Source Tree

This directory is the canonical in-repo standard-library source tree for the
current explicit-root model. Files here are ordinary TypeLisp modules loaded by
the same `import` mechanism as project-local files.

This document describes the source-tree convention only. TypeLisp package
builds support local path dependencies and `pkg:<alias>/...` imports through
`typelisp.pkg`, but the stdlib is not currently distributed as a package.
TypeLisp still does not define registry or version solving, default
installed-root discovery, namespace isolation, or an implicit prelude.

The in-tree unsized `(Array T)` migration census lives in
[`DYNAMIC_ARRAY_CENSUS.md`](DYNAMIC_ARRAY_CENSUS.md). Check it before adding a
new public growable collection surface or migrating an existing dynamic-array
use.

## Current Modules

- `arena.tl`: typed first-class `Arena`, `ArenaMark`, and `ArenaPhase` helper
  declarations for manual allocation control. `arena.make`,
  `arena.make-atomic`, `arena.current`, `arena.mark`, `arena.phase`,
  `arena.rewind-safe!`, and `arena.destroy-safe!` are safe under their checker
  proofs; raw switching, destroying, and rewinding helpers require
  `(unsafe ...)`. Import it with `(import stdlib.arena)`.
- `atomic.tl`: explicit sequentially consistent atomic integer operations on
  one dynamic-array element. The first surface supports `i32` and `i64`
  load/store/add/fetch-add helpers and is the only safe overlap-tolerant SPMD
  scatter write path; ordinary `array-set!` remains non-atomic. Import it with
  `(import stdlib.atomic)`.
- `args.tl`: reusable argv option parser over explicit specs. It supports
  short/long boolean flags, short/long value flags, repeated options,
  positional preservation, and `--` end-of-options handling, with structured
  missing-value and unknown-option diagnostics. The intended CLI migration path
  is for selfhost command modules to define local specs and replace hand-rolled
  flag loops incrementally. Import it with `(import stdlib.args)`.
- `byte_buf.tl`: owned mutable binary byte buffers backed by active-arena
  `(Array u8)` storage. The `byte-buf-*` API covers construction, capacity
  inspection, reserve/growth, push, append/copy from arrays and strings, live
  range reads/writes, clear/reuse, copy-out to arrays or strings, and borrowed
  immutable/mutable `bytes` views over strings, buffers, and byte sub-slices.
  Import it with `(import stdlib.byte_buf)`.
- `byte_buf_core.tl`: lightweight append-only binary byte builder for compiler
  and runtime hot paths that need construction, push, append, reserve, length,
  and explicit finish/copy boundaries without importing the full borrowed
  `bytes` view surface. Import it with `(import stdlib.byte_buf_core)`.
- `comptime.tl`: public stdlib-owned declarations for well-known macro syntax
  and reflection values (`Expr`, `ExprList`, `ExprClause`, `ExprClauseList`,
  `ExprBindingClause`, `ExprBindingClauseList`, `Pattern`, `PatternList`,
  `MatchArm`, `MatchArmList`, `TypeInfo`, and dense sequence wrappers), plus
  exported compile-time helper signatures such as `expr-int`,
  `expr-list-nth`, `expr-clause-list->expr-list`, `pattern-variant`,
  `pattern-list-bindings`, `match-arm`, and `expr-match`. `expr-type` returns
  the produced type of a captured expression for macro-time reflection. Dense
  sequence accessors use the public `items` and `len` fields in ordinary stdlib
  source; remaining compiler intrinsics are syntax constructors, reflection
  helpers, and provenance-preserving sequence conversions such as
  `expr-clause-list->expr-list` and
  `expr-binding-clause-list->expr-list`.
  The compiler verifies these shapes when the module is loaded and maps the
  syntax declarations and helper calls to the current compile-time-only macro
  representation during the CTFE migration. Import it with
  `(import stdlib.comptime)`.
- `io.tl`: file I/O helpers, explicit file-handle open/close wrappers, stdio
  wrappers, argv access, panic/error, deterministic float parse/format support,
  and monomorphic Result-style I/O error APIs built as stdlib extern wrappers
  over backend runtime symbols. Import it with `(import stdlib.io)`.
- `io_core.tl`: private backing module for `io.tl` file-handle table storage.
  User programs should import `stdlib.io`; this module exists to keep raw handle
  internals out of the public `stdlib.io` surface.
- `io_caller_result.tl`: lifetime-preserving `read-file-or-result` surface that
  can return a borrow of the caller fallback or owned file contents. Import it
  with `(import stdlib.io_caller_result)`; it remains separate from
  `io.tl` while the compatibility wrapper keeps the owned `String` API.
- `iterator.tl`: stdlib iterator protocol conventions plus the first scalar
  value/range iterable, `I64Range`. The protocol is module-level rather than
  trait-based: a collection exposes an iterator constructor, and iterator state
  exposes `next` as a mutable-state step returning an option-like result. The
  current flat compatibility names are `range`, `range-inclusive`,
  `i64-range-iterator`, and `i64-range-next`; repeated `next` after exhaustion
  returns `I64RangeDone`.
  Import it with `(import stdlib.iterator)`.
- `env.tl`: recoverable environment variable lookup and PATH-style list/vector
  helpers, including the stdlib-owned `var-exists?`, `var-value`, and
  target-cfg-derived `path-separator` wrappers. Lookups are implemented
  entirely in TypeLisp (#2142 follow-up): the Linux side walks the SysV
  stack-captured environment through the `program-argv`/`program-argc` builtins
  (`envp = &argv[argc+1]`), and the Windows side scans the
  `GetEnvironmentStringsA` block (case-insensitively) via a direct kernel32
  binding, replacing the former backend `getenv`/`strlen` libc shims.
  `path-list`, `path-split`, and `path-join` remain list-compatible
  wrappers; new append-heavy callers should use the `StringVec` variants
  `path-list-vec`, `path-split-vec`, and `path-join-vec`. Import it
  with `(import stdlib.env)`.
- `cpu.tl`: host CPU SIMD ISA detection via stdlib-owned `cpuid`/`xgetbv`
  wrappers over backend runtime symbols (#1167). `runs-avx2?` /
  `runs-avx512f?` / `runs-avx512bw?` report an ISA as runnable only when both
  the CPUID feature bit and OS XSAVE state (XCR0) are present, plus the
  underlying `osxsave?` / `xcr0` / `max-leaf` / `has-avx2?` /
  `has-avx512f?` / `has-avx512bw?` accessors. Backs
  `scripts/detect_simd_isa.tl`, which replaced the C cpuid probe (#1168). The
  `defdispatch` runtime SIMD dispatch design in `SPEC.md` uses the same
  capability model internally; ordinary dispatched calls should not require user
  code to import this module. Import it
  with `(import stdlib.cpu)` when code needs explicit host capability
  checks.
- `core_macros.tl`: typed expression macros for core guard and boolean forms.
  The compile driver imports it as an implicit prelude, so bare `when`,
  `unless`, `and`, `or`, and bracket-arm `cond` are available without imports.
  `cond` requires `(cond [test expr] ... [else fallback])`; flat
  `(cond test expr ... fallback)` calls are rejected. Repository code should use
  the bare prelude forms; the explicit qualified API surface is covered by
  `tests/core_macros_api.tl`.
- `array.tl`: public dynamic/fixed array helper macros that expand to
  compiler-private array intrinsics during the #3421 migration. Import it with
  `(import stdlib.array)` when new code should depend on the stdlib-owned
  array surface instead of transitional compiler-public aliases.
- `fs.tl`: minimal recoverable filesystem helpers for tool artifact paths,
  current-directory lookup, lexical path normalization, safe relative suffix
  checks, temporary directories, cleanup, process ids, coarse file-kind probes,
  and vector-backed directory listing, with public status helpers bound directly
  to platform externs where available. Import it with `(import stdlib.fs)`.
- `ffi.tl`: FFI buffer helpers, including explicit NUL-terminated borrowed
  `bytes` copies into caller-owned `(MutPtr u8)` storage and active-arena
  `(Ptr u8)` C string allocation. Compatibility `String` wrappers borrow their
  input text and delegate to the byte-slice path. Import it with
  `(import stdlib.ffi)`.
- `hash.tl`: deterministic, non-cryptographic hash and key equality helpers for
  future collections. Import it with `(import stdlib.hash)`.
- `hashmap.tl`: generated concrete hashmap family (collections v1, #817) over
  open-addressed linear-probing slot arrays. `StringI64Map` remains the
  compatibility `String -> i64` map, while generated `StringStringMap`,
  `I64I64Map`, and `I64StringMap` add `String -> String`, `i64 -> i64`,
  and `i64 -> String` instantiations with the same API shape:
  `*-map-with-capacity` / `-insert` / `-put` / `-get` /
  `-contains?` / `-remove` / `-update-if-present` / `-insert-or-update` /
  `-entry-or-insert` / mutable-entry helpers / `-len` / `-capacity`,
  tombstone accounting,
  resize/rehash helpers, and deterministic bucket-order iteration through
  `-next-occupied` / `-entry-at`. String-key maps expose borrowed-key lookup,
  containment, removal, and update helpers such as
  `string-string-map-get-borrowed` and
  `string-string-map-update-borrowed-if-present`; owned-key wrappers remain for
  compatibility. Generated metadata uses explicit key descriptor identities:
  `stdlib/hashmap/string-key-v1` for `String` keys and
  `stdlib/hashmap/i64-key-v1` for `i64` keys; unsupported key types are not
  inferred through traits. These descriptors also support nominal struct and
  enum value types; values move into the map, owned lookup moves the value out
  through the result, and `*-get-value-borrowed` returns a map-lifetime borrow
  for field or payload inspection until the map is mutated. Aggregate keys are
  still unsupported. Use these stdlib maps for ordinary program data and keep
  compiler-specialized symbol tables where their value domain or lifecycle is
  deliberately narrower. Import it with
  `(import stdlib.hashmap)`. Module imports such as
  `(import (hashmap String String) as map)` expose the same scalar families
  with `Map`, `&` readers, and `&mut` in-place mutators.
- `set.tl`: module-emitting `(set T)` macro over the same open-addressing
  storage model as `hashmap.tl`. Generated modules currently support `i64` and
  `String` keys and expose `Set`, `with-capacity`, `new`, immutable-ref
  `contains?` / `len` / `capacity`, mutable-ref `insert` / `remove`,
  and bucket-order cursor helpers `next-occupied`, `entry-at`, and
  `entry-key-or`. String-key modules also expose borrowed-key containment and
  removal wrappers. Use a set
  when only key membership matters; use a map when each key carries a meaningful
  value rather than modeling membership with dummy map values. Import it with
  `(import stdlib.set)` and instantiate with `(import (set i64) as iset)`.
- `sort.tl`: generated stable deterministic in-place insertion sort helpers for
  `(vector T)` modules. `(vec T)` extends the matching generated vector
  module with `sort!`; scalar element types use built-in `<`, while String and
  aggregate element types pass an explicit less-than function. The module also
  exposes borrowed and owned string less-than helpers. Import it with
  `(import stdlib.sort)`.
- `sync.tl`: semaphore-backed synchronization helpers over `thread.tl`.
  `(channel i64)` emits a bounded `channel_i64.Channel` module whose queued
  scalar messages live in runtime-owned OS memory. `ChannelI64PairChannel` moves
  two-field `ChannelI64Pair` messages; `ChannelString` moves atomic-arena-owned
  string messages through the same bounded channel surface; `(mutex i64)` emits
  a `mutex_i64.Mutex` module that protects a shared scalar through a
  cleanup-owned lexical guard and rejects close while guards or lock attempts
  are live. It also exposes raw `i64` pointer atomic load/store/add/fetch-add/CAS
  wrappers for synchronization internals. Import it with `(import stdlib.sync)`
  and instantiate with `(import (sync.channel i64) as channel_i64)` or
  `(import (sync.mutex i64) as mutex_i64)`. Generated modules expose
  `raw-field-count` as a zero-argument accessor; channels also expose
  `max-capacity`.
- `json.tl`: JSON value parser and serializer for tool protocols and data
  exchange, with vector-backed parser builders that preserve the public
  list-shaped `Json` value model, plus deterministic finite `f64`/`f32` JSON
  number conversion helpers. It is also a `serialize.tl` strategy for scalar,
  fixed-array, dynamic-array, struct, and module-backed enum roots with nested
  structs, arrays, tuples, and supported enum payloads:
  instantiate with `(import (serialize.serialize json Person) as person_json)`
  to get `to-json` / `from-json` aliases alongside generic `encode` / `decode`.
  Import it with `(import stdlib.json)`.
- `math.tl`: pure scalar math helpers with no runtime imports or platform
  externs: absolute value for `i64`, `f64`, and `f32`, plus min, max, clamp,
  and sign predicates for `i64` and `f64`.
  Transcendental/libm-style functions such as `sqrt`, trigonometry,
  `log`, and `pow` are intentionally deferred until a freestanding soft-math or
  explicit platform-extern policy is chosen. Import it with
  `(import stdlib.math)`.
- `option.tl`: module-emitting `(option T)` macro for absence-only results.
  Import it with `(import stdlib.option)` and instantiate with a module
  alias such as `(import (option i64) as option_i64)`. Each generated module
  exposes `Option`, `some`, `none`, borrowed predicates `is-some?` /
  `is-none?`, consuming `value-or`, and same-payload `map`; duplicate imports
  for the same payload type share the generated module/type.
- `result.tl`: module-emitting `(result T E)` macro for recoverable-error
  results with success payload `T` and error payload `E`. Import it with
  `(import stdlib.result)` and instantiate with a module alias such as
  `(import (result i64 String) as result_i64_string)`. Each generated module
  exposes `Result`, `ok`, `err`, borrowed predicates `is-ok?` / `is-err?`,
  consuming `value-or`, and same-payload `map`; duplicate imports for the same
  success/error pair share the generated module/type.
- `serialize.tl`: format-generic value serializer macro. Import it with
  `(import stdlib.serialize)`, import a format strategy module, then instantiate
  with `(import (serialize.serialize fmt Person) as person_ser)` or a scalar or
  array root such as `(import (serialize.serialize fmt (Array i64)) as i64s_ser)`.
  The generated module exposes `encode` / `decode` over the strategy's `Value`
  type, a local `Result` enum, and any format-specific declarations emitted by
  the strategy's `extra-decls` hook. Current serializers cover primitive roots,
  fixed-array roots, dynamic-array roots, struct roots, module-backed enum roots,
  nested structs, arrays, enum values, and tuples within supported roots. Enums
  reuse object and sequence hooks as `{ tag: String, payload: [...] }`. Direct
  struct enum payloads, generated option/result family enum reflection, tuple
  roots remain follow-ups.
  Strategy hooks own object and sequence representation, decode diagnostics, and
  helper aliases. The checked toy format exercises the hook contract, and
  `json.tl` provides the JSON integration strategy.
- `process.tl`: process command/output/error data model and the public
  `output`/`start`/`wait` wrappers for selfhost tools.
  `ProcessCommand` keeps the existing list-backed argv/env runtime boundary and
  also exposes `StringVec` argv conversion helpers plus `ProcessEnvVec`, a
  parallel-`StringVec` env builder surface. Vector argv helpers convert once
  while preserving order. Inherited environment entries whose names match an
  override are removed, vector override entries are emitted in vector order after
  inherited entries, and duplicate override names are preserved in that order.
  Import it with
  `(import stdlib.process)`.
- `process_runtime.tl`: TypeLisp implementation of the process-execution runtime
  (`tl_process_output`/`tl_process_start`/`tl_process_wait`) that `process.tl`
  calls — Linux uses raw syscalls (fork/execve with memfd-captured output),
  Windows uses kernel32 `CreateProcessA` with temp-file redirection. Replaces the
  former backend assembly (#2142 slice 4); imported transitively via `process.tl`.
- `profile.tl`: runtime profiling helpers for coarse elapsed time and
  allocation counters. `now-ms` is implemented in TypeLisp over
  platform FFI/syscalls; allocator counters still use allocator-runtime hooks.
  The public helpers are `now-ms`, `alloc-total`, `alloc-live`, `alloc-peak`,
  and `alloc-reset-peak`. Import it with
  `(import stdlib.profile)`.
- `queue.tl`: generated growable deque family (collections v1, #1549/#2797)
  over a circular `(Array T)`. Import `(queue.deque T)` with a module alias,
  such as `(import (queue.deque i64) as deque_i64)`, to get `Deque`, `Pop`, `new`,
  `with-capacity`, `push-back`, `push-front`, `pop-front`, `pop-back`,
  `peek-front`, `peek-back`, `get`, `len`, `capacity`, and `is-empty?` in that
  generated module namespace. Mutators take `&mut` and update in place; reads
  take `&`, peeks/get use caller fallbacks, and empty pops return `Pop.Empty`.
  Import the macro with `(import stdlib.queue)`.
- `random.tl`: deterministic, seeded, non-cryptographic random helpers,
  array/vector/list weighted-index selection for selfhost tools, and an
  OS-entropy seed source. Import it with `(import stdlib.random)`.
- `runtime.tl`: always-linked runtime prelude. Holds the fault/abort handlers
  (out-of-bounds, divide-by-zero, shift) the backend emits checks against, plus
  the low-level OS write/exit primitives they use, as TypeLisp exported under
  fixed symbols via `(:export-symbol …)` (#2143/#2142). Imported implicitly into
  every executable; programs do not import it by hand.
- `string.tl`: string utility functions built on compiler/runtime primitives,
  including append/concat-all, substring, equality, integer rendering, and
  integer parsing helpers. Import it with `(import stdlib.string)`.
- `str_cat.tl`: the variadic `str-cat` concatenation macro, which expands to a
  single-allocation copy regardless of arity. Kept separate from
  `core_macros.tl` so importing it does not shadow core guard/boolean macro
  forms. Import it with `(import stdlib.str_cat)` and call `str_cat.str-cat`;
  compatibility fixtures may still exercise old flat import behavior until the
  final legacy-import removal.
- `string_caller_result.tl`: lifetime-preserving string replacement
  caller-result surface. It exposes `string-replace-result`, which selects
  between no-match borrowed results and replacement-owned results. Import it
  with `(import stdlib.string_caller_result)`; it remains separate from
  `string.tl` while the compatibility wrapper keeps the owned `String` API.
- `test.tl`: minimal assertion helpers for TypeLisp fixtures. Import it with
  `(import stdlib.test)`.
- `thread.tl`: minimal native thread primitives for selfhost worker pools:
  spawn/join for `(-> i64 i64)` entries, counting semaphores, and default worker
  count, plus generated `(thread.handle T)` modules for checked scalar nullary
  closures such as `(import (thread.handle i64) as thread_i64)` with
  `thread_i64.Handle`, `thread_i64.spawn`, and `thread_i64.join`.
  `thread.spawn-string`/`thread.join-string` and
  `thread.spawn-array-i64`/`thread.join-array-i64` and
  `thread.spawn-box-i64`/`thread.join-box-i64` run the task in a fresh atomic
  arena before returning the joined aggregate. Linux uses raw clone/futex/eventfd
  syscalls; Windows uses kernel32 threads and semaphores. Import it with
  `(import stdlib.thread)`.
- `time.tl`: portable millisecond timestamp helpers separate from profiling
  counters. `unix-ms` returns wall-clock Unix epoch milliseconds and
  `monotonic-ms` returns monotonic elapsed milliseconds, both as
  `ResultTimeMs`. Calendar conversion, formatting, time zones, locale,
  sleeping, and timers are deferred. Import it with `(import stdlib.time)`.
- `text_buf.tl`: arena-aware text buffer helpers for incremental String
  construction with owned `TextBuf` chunks and the shared ordered-chunk render
  helper used by the borrowed companion. Its declarations are emitted from
  `text_buf_family.tl`; import it with `(import stdlib.text_buf)`.
- `text_buf_borrowed.tl`: lifetime-parameterized `TextBufBorrowed`
  borrowed-chunk companion surface. Import it with
  `(import stdlib.text_buf_borrowed)`; it remains separate from
  `text_buf.tl` while the compatibility surface keeps owned chunk storage, but
  both surfaces are emitted from `text_buf_family.tl` and adapt to the owned
  render helper at explicit materialization boundaries.
- `text_buf_family.tl`: declaration-emitting generator source for the owned
  `TextBuf` and borrowed `TextBufBorrowed` families. It is imported by the
  public text-buffer modules rather than by ordinary callers.
  This is the reference pattern for flat compatibility twins that cannot yet
  become generated module imports: keep the stable public modules as thin shells,
  splice shared declarations from one `: Decls` generator, and leave only
  caller-site compatibility macros or inline tests in the shell.
- `vector.tl`: generated concrete vector family (collections v1, #835/#1989)
  over `(Array T)`, with `I64Vec` preserved as the compatibility template and
  `StringVec` added as the first non-i64 stdlib instantiation. Both provide
  `*-vec-with-capacity` / `-new` / `-push` / `-pop` / `-get` / `-last` /
  `-set!` / `-len` / `-capacity`, with doubling growth, bounds-checked reads,
  and conversion/iteration helpers `-from-array` / `-to-array` / `-extend` /
  `-reverse!` / `-contains?`; `I64Vec` also keeps `-sum` and adds owned-vector
  higher-order `i64-vec-fold*` / `i64-vec-map*` helpers that take function
  values. The module also exposes the module-emitting `(vector T)` macro for
  import-time instantiations such as `(import (vector i64))` or
  `(import (vector String) as svec)`. Each instantiation provides a generated
  module namespace with `Vec`, `Pop`, `new`, `with-capacity`, immutable-ref
  reads, mutable-ref `push` / `set` / `pop` updates, mutable `len-mut` /
  `slots-mut` accessors for generated in-place algorithms and SPMD loops,
  conversion helpers, and fold/map/contains helpers. Borrow `slots` /
  `slots-mut` outside `foreach` when SPMD code needs backing storage without
  public `(Array T)` signatures. It also keeps the named `vector-family` macro
  for flat no-pop compatibility families that need stable local names. The
  family metadata is not scalar-only: checked
  fixtures cover
  nominal enum and struct element types, with `push`/`set!` moving values into
  array slots, `pop` moving the last element out, and growth/snapshot helpers
  copying the live prefix through the same move semantics. Current aggregate
  slots use the handle representation; after the inline-aggregate flip
  (#1867/#2357), the same API stores aggregate elements inline in the backing
  array. Use generated vectors for append-heavy private sequences and keep
  recursive enum lists for AST/list structures where the cons shape is the
  modeled data. Import it with `(import stdlib.vector)`.
- `vector_slice.tl`: lifetime-scoped typed slice views generated by the
  `(slice T)` module macro over the matching `(vector T)` module and explicit
  `(Array T)` live prefixes. Import the module with
  `(import stdlib.vector_slice)`, then instantiate concrete modules such as
  `(import (slice i64) as i64s)`. Each generated module provides immutable
  `Slice`, mutable `MutSlice`, `from-vec`, `from-array`, `all-vec`,
  `from-vec-mut`, `from-array-mut`, `all-vec-mut`, `get`, `set`, `len`,
  `mut-len`, `is-empty?`, `mut-is-empty?`, `sub-slice`, `to-array`, `to-vec`,
  and value-threaded iterator helpers. Generated slice fields `slots`, `start`,
  and `len` are exported so SPMD code can borrow backing storage before a
  `foreach` body while keeping public signatures on vector/slice views. Invalid
  ranges return empty views, and explicit copy boundaries allocate owned
  array/vector storage.
- `msvc.tl`: MSVC tool discovery (`link.exe` + `PATH`/`LIB`/`INCLUDE` command
  environment) from a configured Developer Command Prompt. Import it with
  `(import stdlib.msvc)`.

## Backend Runtime Helper Ownership

The backend runtime plan is a compatibility boundary, not a place for new
stdlib APIs by default. The checked inventory in
`src/compiler_backend.tl` (`compiler-backend-runtime-helper-owner`) is the
authoritative ownership table for runtime symbols. `compiler-backend-plan-provides?`
rejects unclassified plan helper names, and the backend self-test also checks
the exact global-symbol allowlist emitted by the full runtime-helper assembly.

- **Core runtime:** the backend-owned allocator/arena substrate:
  `tl_alloc`, `tl_region_mark`, `tl_region_reset`, `tl_arena_make`,
  `tl_arena_make_atomic`, `tl_arena_current`, `tl_arena_set`, `tl_arena_destroy`,
  `tl_arena_poison_enable`, `tl_thread_init`, and `tl_thread_entry_ptr`. These
  helpers are irreducible backend runtime because they bootstrap ordinary
  TypeLisp allocation, own the single `tl_current_arena` slot, touch
  target-specific TLS (`%fs:tl_current_arena@tpoff` on Linux and `%gs:0x28` on
  Windows), and must stay import-free and allocation-free on allocation/reclaim
  paths. Their checked OS-call inventory is Linux `mmap`/`munmap` in
  `tl_alloc`, `tl_arena_make`, `tl_arena_make_atomic`, `tl_arena_destroy`, and
  `tl_region_reset(0)`, plus the current arena make fatal-exit syscalls;
  Windows uses kernel32 `VirtualAlloc`/`VirtualFree` in the corresponding page
  acquisition/release paths. Nonzero `tl_region_reset(mark)` retires overflow
  chunks on the arena root instead of releasing them immediately, and reset-all
  or destroy releases those retained chunks. Revisit this classification after
  #3290 provides an allocation-free TLS access design.
- **Core ABI / entry / primitive helpers:** `tl_memcpy` is the backend block-copy
  primitive itself and remains core until source code can express an equal or
  better overlap-safe copy primitive. `tl_memchr` is the allocation-free byte
  search primitive used by borrowed string/byte scans until source code can
  express equally efficient raw byte search. `tl_tlci_call_image_entry` is the
  raw C-ABI bridge that lets the tlci loader call a mapped `tlci_image_entry`
  address with the host callback table and writable registration record.
  Windows `__chkstk` is required by the MSVC ABI for large stack frames. Windows
  `tl_setup_argv` and `_tl_start` are the freestanding entry bootstrap: they
  build the initial argv block from `GetCommandLineA`, clear the TEB
  current-arena slot, call `main`, and exit via `ExitProcess`.
- **Stdlib FFI wrapper dependency:** backend shims still needed by stdlib
  wrappers around OS/profile surfaces: `tl_profile_alloc_total`,
  `tl_profile_alloc_live`, `tl_profile_alloc_peak`,
  `tl_profile_alloc_reset_peak`. The accessors are simple global reads/writes,
  but their counters are maintained inside the backend allocator core, so the
  accessor boundary travels with that allocator ownership for now.
- **Stdlib TypeLisp migration target:** compatibility runtime helpers whose
  preferred long-term owner is TypeLisp stdlib code or a narrower stdlib FFI
  boundary: `tl_substring`, `tl_string_concat`, `tl_string_concat3`,
  `tl_string_concat4`, `tl_string_concat5`, `tl_int_to_string`,
  `tl_atomic_i64_load_ptr`, `tl_atomic_i64_store_ptr`,
  `tl_atomic_i64_add_ptr`, `tl_atomic_i64_fetch_add_ptr`,
  `tl_atomic_i64_cas_ptr`, `tl_atomic_i32_load_ptr`,
  `tl_atomic_i32_store_ptr`, `tl_atomic_i32_add_ptr`,
  `tl_atomic_i32_fetch_add_ptr`, and `tl_atomic_i32_cas_ptr`. The string
  construction helpers are already exported from TypeLisp by #3291 while the
  runtime-plan names remain recognized for compatibility call-site tracking.
  Atomic helper migration is tracked by #3292 now that #3289 supplies the
  underlying atomic memory-operation intrinsics. String equality, string
  parsing, and string hashing are implemented by TypeLisp stdlib code in
  `string.tl` and `hash.tl`. Bounds/division/shift/general/OOM abort handlers,
  file/IO/process/fs helpers, primary env implementations, random seed,
  profile time, and CPU feature helpers have moved to TypeLisp
  stdlib/runtime-prelude exports or direct platform bindings; only the env
  compatibility aliases below remain recognized by the plan table.
- **Compatibility alias:** legacy env spellings recognized by the runtime-plan
  ownership table: `tl_env_var_exists`, `tl_env_var_value`,
  `path-separator`. Their backend emitters are empty because
  `stdlib/env.tl` owns environment lookup in TypeLisp (#2142 follow-up), and
  source builds use the `env.tl` wrappers directly.
- **Deprecated/delete candidate:** no current runtime-plan symbols are in this
  category. Add symbols here only with a linked removal owner.

The broader runtime-core boundary tracker is #1897. New stdlib features should
prefer TypeLisp implementations or focused stdlib FFI wrappers; new backend
helpers need an explicit ownership entry and a focused migration or retention
issue when they are not core runtime.

## Arena Allocation Policy

The stdlib does not own an allocator API. Stdlib functions allocate only by
calling compiler/runtime primitives or stdlib wrappers such as `substring`,
`string-append`, `read-file`, `int->string`, and aggregate constructors. Those
allocations use the active arena: the default program-lifetime arena outside
any scoped arena, or the innermost scoped arena inside `(with-arena ...)`. The
arena model uses the term "scoped arena" for this behavior. Stdlib policy tests
use `(with-arena ...)` as the executable witness for active-arena semantics.

Use four standard scratch patterns:

- **Temporary scratch only:** put phase-local work in `(with-arena scratch ...)`
  and return only scalars or values allocated outside the scoped arena. This is
  the preferred safe path and uses no `stdlib/arena.tl` unsafe helpers.
- **Clone one result out:** allocate a reusable first-class arena with
  `arena.make`, then wrap each transient build in `(with-escape scratch ...)`.
  Supported body results are cloned into the enclosing active arena before the
  scratch arena is rewound.
- **One-shot clone-out:** use `(with-scratch body ...)` when a supported result
  should be cloned out of a fresh scratch arena and the caller does not need to
  reuse the arena handle.
- **Keep results in a first-class arena:** allocate or receive a typed `Arena`
  and wrap the build in `(in-arena arena ...)`. The result remains owned by that
  first-class arena.
- **Safe ordinary arena invalidation:** import `stdlib.arena`, record a phase
  token with `arena.phase`, allocate phase-local values through
  `(in-arena owner ...)`, then call `arena.rewind-safe!` when the checker can
  prove every value from that phase is dead. Use `arena.destroy-safe!` only when
  all values from the ordinary owner are dead.
- **Manual unsafe arena:** import `stdlib.arena` and call `arena.set!`,
  `arena.rewind`, or `arena.destroy` only inside `(unsafe ...)` when the caller
  can prove every invalidated heap handle is dead. Prefer the safe patterns
  above for normal tool code.

Written reference and arena lifetime syntax exists, and stdlib APIs migrate
non-consuming text inputs to borrowed `(& lifetime str)` signatures as the
borrowed `str` frontend and string API work lands (#1453/#1454/#1082). The checker
conservatively tags aggregate results from stdlib calls made inside a scoped
arena as arena-owned, which prevents those values from escaping the scope. The
v1 `String`/`str` contract in `SPEC.md` classifies which future signatures
should take borrowed text and which should return owned active-arena strings.
`SPEC.md` also reserves the binary-storage family: `stdlib/byte_buf.tl` exposes
owned `ByteBuf` helpers for mutable binary data plus borrowed `bytes` views over
strings, buffers, and byte sub-slices, while `stdlib/byte_buf_core.tl` keeps a
narrow append-builder surface for hot internal code. `TextBuf` remains an
append/render text builder, and `vector_slice.tl` remains a generated typed
collection-slice precedent; neither is the raw byte-slice contract.
The `string_caller_result.tl`, `io_caller_result.tl`, and
`process_borrowed.tl` companion modules expose lifetime-preserving shapes.
Borrowed process runtime wrappers copy at the owned boundary, while ordinary
owned stdlib imports keep the compatibility wrappers.

| Functions | Allocation behavior |
|-----------|---------------------|
| `string.is-char-whitespace`, `string.char-eq`, `string.index-of-byte`, `string.contains`, `string.contains-char`, `string.is-string-prefix-at` | Non-allocating string/char inspection; text parameters are borrowed `str` inputs. |
| `string.append`, `string.concat`, `string.copy`, `string.substring`, `string.slice`, `string.concat-all` | Copying string helpers allocate fresh active-arena `String` storage and copy bytes from borrowed `str` inputs. Owned `String` places auto-borrow at call sites, and stdlib code that already has `(& r str)` values calls the same public helpers directly. `string.concat-all` is the packed-array target for long `str-cat` expansions and still consumes an owned `(Array String)` pack. |
| `int->string` | Allocates fresh active-arena `String` storage, writes decimal bytes directly, and returns the zero, positive, negative, and signed edge-case spelling without calling the legacy runtime helper. Project callers should import the stdlib helper instead of relying on an unimported compiler default. |
| `string-trim-left`, `string-trim-right`, `string-trim` | Borrow the input text and return fresh `String` storage from `substring`, allocated in the active arena. |
| `string-replace` | Compatibility wrapper: returns fresh `String` storage from `substring`/`string-append` when a replacement is made; returns the caller-provided `s` when `old` is not present. `string_caller_result.tl` exposes the `string-replace-result` caller-result shape that preserves the no-match borrow until explicit materialization. |
| `try-read-file` | Performs host file inspection through stdlib FFI; returns `OkIoString` with fresh active-arena `String` storage from `read-file` when the path is readable, or `ErrIoString` for empty paths, expected absence, permission failures, interrupted reads, and target status-code failures. |
| `try-write-file` | Writes through the recoverable stdlib status helper; returns `OkIoUnit` on success or `ErrIoUnit` for empty paths, missing parents, permission failures, interrupted writes, and target status-code failures. |
| `try-file-exists?` | Returns `OkIoBool` for existing or expected missing paths; empty paths and hard probe failures return `ErrIoBool`. |
| `try-append-file` | Appends through the recoverable stdlib status helper. It preserves existing contents, creates missing files, does not allocate a concatenated temporary string, and uses best-effort host append semantics rather than truncating or rewriting the whole file. |
| `file-open`, `file-close` | `file-open` returns `ResultIoFile` with an opaque stdlib-managed `FileHandle` for `OpenRead`, `OpenWriteTruncate`, and `OpenWriteAppend`. The stdlib copies the path into active-arena storage for the host call and tracks handle state in a process-global table. `file-close` releases a valid handle and returns `IoUnsupported` for invalid or already-closed handles. |
| `file-read-chunk`, `file-read-bytes`, `file-read-eof?` | `file-read-chunk` reads up to the requested byte count from a read-mode `FileHandle` and returns `ResultIoRead` with active-arena `String` bytes plus the sticky EOF flag. Negative counts return `IoInvalidPath`; closed, invalid, write-only, and unsupported handles return `IoUnsupported`. The accessors are non-allocating field reads on `FileRead`. |
| `file-write`, `file-flush` | `file-write` writes a `String` to an `OpenWriteTruncate` or `OpenWriteAppend` handle, retrying host short writes until complete or an error is reported. `file-flush` flushes a write-mode handle. Closed, invalid, read-only, and unsupported handles return `IoUnsupported`. |
| `read-file-or` | Compatibility wrapper over `try-read-file`; returns the caller-provided `fallback` for every structured error. `io_caller_result.tl` exposes a `read-file-or-result` shape that preserves the fallback borrow on error paths and owned file contents on success. |
| `append-file` | Panic-on-error convenience wrapper over `try-append-file`; preserves existing contents and creates missing files through host append mode. |
| `file-nonempty?` | Convenience wrapper over `try-read-file`; allocates a temporary active-arena `String` through `read-file` only when the path exists. |
| `stdin-read-line`, `stdin-read-bytes` | Return `StdinRead` aggregates containing an active-arena `String` plus the post-read sticky EOF state. Byte reads still use `String` storage until the `ByteBuf`/`bytes` split lands. |
| `stdin-at-eof?`, `stdin-read-text`, `stdin-read-eof?`, `stdout-write`, `stderr-write`, `stdout-flush` | Non-allocating wrappers/accessors around stdlib FFI stdio helpers and `StdinRead` values. |
| `stdout-write-line`, `stderr-write-line` | Allocate a newline-appended active-arena `String` via `string-append`, then write it to the target stream. |
| `get`, `path-list`, `path-list-vec`, `path-split`, `path-split-vec`, `path-join`, `path-join-vec` | Lookup names, split inputs, and explicit join separators are borrowed `str` inputs. Environment values and split/join results allocate fresh active-arena Strings and either vector backing arrays or compatibility list spines when runtime values are read or string pieces are created; missing variables return explicit `EnvNo*` options. |
| `path-join`, `path-join-owned-pair`, `path-join-many`, `dirname`, `basename`, `extension`, `path-absolute?`, `path-normalize`, `path-safe-relative?`, `try-current-dir`, `try-mkdir`, `try-mkdir-if-missing`, `try-remove-file`, `try-remove-dir`, `try-rename`, `try-read-dir`, `try-read-dir-vec`, `try-file-kind`, `try-file-metadata`, `try-create-temp-dir` | Path joins allocate active-arena Strings when a separator is inserted or duplicate separator is removed. `path-join` remains the two-argument borrowed function; `path-join-owned-pair` accepts two owned `String` segments and delegates to it; `path-join-many` is the variadic macro alias for owned `String` segments, expanding zero segments to `""`, one segment to that segment, and two or more segments to pairwise joins that delegate to `path-join`. `dirname`/`basename`/`extension` are pure separator-agnostic string helpers (no allocation beyond the returned substring; `extension` operates on the basename and treats a leading-dot name as extensionless). `path-absolute?` is non-allocating and treats `/...`, `\\...`, `C:/...`, and `C:\\...` as absolute/rooted while leaving drive-relative `C:...` non-absolute. `path-normalize` is lexical only: it accepts `/` and `\\`, collapses repeated separators, removes `.`, resolves `..` against normal segments with a `StringVec` stack, preserves relative leading `..`, preserves roots and drive roots, renders `/` as the stable separator on every host, and returns `"."` for empty relative paths. `path-safe-relative?` allocates through normalization and returns true only for non-empty relative suffixes that remain below a caller-chosen root after lexical normalization; it rejects rooted, drive-qualified, empty/`.` and leading-parent paths. `try-current-dir` returns the host-reported cwd as an owned active-arena `String` on Linux and Windows through stdlib FFI, without symlink canonicalization. Recoverable filesystem helpers map host/runtime status codes into `IoError`; `try-file-kind` returns `FsFileRegular`, `FsFileDirectory`, or `FsFileOther` on Linux and Windows. `try-file-metadata` returns `FsMetadata` with coarse kind and regular-file byte size on Linux and Windows; directory and other node sizes are zero in this first slice. `try-mkdir` works on Linux and Windows, `try-mkdir-if-missing` treats an already-existing path as success, and `try-rename` follows host rename/replacement behavior. `try-read-dir` and `try-read-dir-vec` return entry names only in a `StringVec`, filter `.` and `..`, preserve host directory order without promising stable sorting, and allocate returned storage and entry strings in the active arena; Linux reads directories directly through syscalls, while Windows uses kernel32 `FindFirstFileA`/`FindNextFileA`. Linux temp directories are created under `$TMPDIR` or `/tmp` with process-id and retry suffixes. Windows temp directories are created under `%TEMP%`, `%TMP%`, or `.` with process-id and retry suffixes. |
| `ffi-c-bytes-*`, `ffi-cbytes`, `ffi-c-string-*`, `ffi-cstr` helpers | `ffi-c-bytes-required-bytes`, `ffi-c-bytes-interior-nul?`, and `ffi-c-bytes-copy!` inspect or copy borrowed `(& r bytes)` into caller-owned `(MutPtr u8)` storage without allocating. `ffi-c-bytes-copy!` validates interior NUL bytes and capacity before writing, appends the trailing NUL on success, and leaves raw-pointer validity/lifetime with the caller. `ffi-c-bytes-alloc` and `ffi-cbytes` allocate a NUL-terminated byte buffer in the active arena, return null for interior NUL input, and keep the returned `(Ptr u8)` valid only until the owning arena is rewound, reset, or destroyed. The `ffi-c-string-*` and `ffi-cstr` compatibility wrappers borrow `String` inputs as bytes and delegate to the same implementation. |
| `hash-*` helpers | Deterministic, non-cryptographic hash and key equality helpers are non-allocating; string hash/equality helpers borrow text inputs. Hashes are stable bucket hints only; collection users must still compare colliding candidate keys with the matching equality predicate. |
| `math-*` helpers | Pure scalar arithmetic/comparison helpers are non-allocating and import no runtime or platform externs. The `abs` macro covers typed `f64` and `f32` expressions; `i64` uses `math-i64-abs`/`math-i64-abs-or` for explicit signed-min behavior. V1 intentionally excludes `sqrt`, trigonometry, `log`, `pow`, and other libm-style functions until a freestanding or explicit platform-extern policy is chosen. |
| `array.tl` helper macros | Macro wrappers add no allocation by themselves. `make-array` allocates and initializes dynamic-array storage under the same rules as the compiler intrinsic; `array-length` and `array-ref` inspect existing storage, `array-set!` mutates existing storage, and `array-push!` may grow dynamic-array backing storage. |
| `string-i64-map-*`, `string-string-map-*`, `i64-i64-map-*`, `i64-string-map-*`, and scalar `(hashmap K V)` module helpers in `hashmap.tl` | Map constructors, growth, resize, and rehash allocate backing slot arrays in the active arena. Flat legacy `insert`, `put`, and `remove` mutate the backing array in place and return the threaded map value; generated-module mutators take `&mut` and update `Map` in place. Lookup, containment, len/capacity/deleted accessors, and bucket-order cursor helpers are non-allocating aside from caller-provided owned keys or fallback values. String-key borrowed lookup/removal variants inspect borrowed key text without copying it. `*-get-value-borrowed` and module `get-value-borrowed` return a lifetime-parameterized lookup whose found branch borrows the map-owned value; mutating/removing/resizing the map while that result is live is rejected by the checker. Mutable-entry helpers such as `string-i64-map-get-mut-entry-borrowed`, module `get-mut-entry*`, `*-mut-entry-present?`, `*-mut-entry-value-or`, and `*-mut-entry-set!` borrow the backing table uniquely and update existing entries in place; another mutable entry, a value borrow, resize, put, or remove is rejected while the entry is live. Missing mutable entries are explicit no-ops, and insertion/growth remains the threaded `*-entry-or-insert`/`*-put` path for flat helpers or `entry-or-insert`/`insert` for modules. |
| `(set T)` generated modules in `set.tl` | Set constructors, insert, remove, growth, resize, and rehash allocate/mutate the backing open-addressed table through the same active-arena policy as `hashmap.tl`. Mutators take `&mut` and update the stored set in place. Duplicate inserts keep `len` unchanged. Lookup, containment, len/capacity accessors, and bucket-order cursor helpers take `&` and are non-allocating aside from caller-provided owned keys. String-key borrowed contains/remove variants inspect borrowed key text without copying it. |
| `i64-vec-*`, `string-vec-*` helpers in `vector.tl` | Vector constructors, growth, push, `from-array`, `extend`, `to-array`, and `i64-vec-map*` allocate backing arrays in the active arena. `i64-vec-map*` traverses owned `I64Vec` handles and returns fresh owned vectors; borrowed slice traversal remains separate in `vector_slice.tl`. `set!` and `reverse!` mutate the existing backing array and return the threaded vector value; `get`, `last`, `len`, `capacity`, `is-empty?`, `contains?`, `sum`, and `i64-vec-fold*` are non-allocating aside from caller-provided fallback/value/function storage. |
| `(vec T)` generated `sort!` helpers and `string-less*` comparators in `sort.tl` | Stable insertion sort helpers extend the matching generated `(vector T)` module, mutate the existing vector backing array in place through a mutable reference, and do not allocate. Scalar instantiations compare values directly with `<`; String and aggregate instantiations use the caller-supplied less-than function and shift only strictly-less values, preserving the relative order of equal elements. |
| `range`, `range-inclusive`, and `i64-range-*` helpers in `iterator.tl` | `range` constructs a half-open scalar iterable over `[start, end)`, and `range-inclusive` constructs an inclusive scalar iterable over `[start, end]` without computing `end + 1`. `i64-range-iterator` constructs non-allocating iterator state from that range value. `i64-range-next` mutates only the iterator state and returns an `I64RangeNext` option-like value; exhaustion and repeated exhaustion do not allocate. The future scalar `for` macro should discover the flat compatibility constructor/step pair as `i64-range-iterator` and `i64-range-next` for `I64Range` until the final module-level protocol reflection replaces these names. |
| `(channel i64)`, `ChannelI64PairChannel`, and `ChannelString` helpers in `sync.tl` | Channel creation allocates runtime-owned OS memory for the fixed ring buffer and head/tail state, plus three OS semaphore handles. Send/recv do not allocate TypeLisp heap storage; they block through the semaphore substrate and move one scalar `i64` message, one two-`i64` `ChannelI64Pair` aggregate, or one atomic-arena-owned `String` handle through the synchronized queue. `channel_i64.close`, `channel-i64-pair-close`, and `channel-string-close` release the OS memory and semaphore handles after all users are done. |
| `(mutex i64)` generated module in `sync.tl` | Mutex creation allocates one runtime-owned scalar slot, one small close-state/live-user control cell, and one OS semaphore handle. `mutex_i64.lock` blocks on the semaphore and returns a cleanup-owned `mutex_i64.Guard`; guarded `get`/`set!`/`add!` do not allocate and `mutex_i64.unlock` releases the semaphore automatically when the `with` scope exits. `mutex_i64.close` returns `false` while guards or lock attempts are live and releases the protected scalar storage and semaphore only when it can permanently mark the mutex closed. The control cell is retained after successful close so copied handles fail closed instead of touching freed storage. |
| `(slice T)` generated helpers in `vector_slice.tl` | `Slice` and `MutSlice` constructors, `get`, `set`, `len`/`mut-len`, `is-empty?`/`mut-is-empty?`, and sub-slicing are non-allocating views tied to a source owner borrow; invalid ranges/counts produce an empty view. `iterator` snapshots the borrowed backing array/start/len, `next` returns an `IterNext` value carrying either the copied item plus next iterator state or the exhausted state, and exhausted iterators remain exhausted when threaded again. `to-array` and `to-vec` are explicit owned-copy boundaries that allocate active-arena storage. |
| `byte-buf-*` and `bytes-*` helpers in `byte_buf.tl` | `ByteBuf` construction, copy-in, reserve, growth, and copy-out allocate in the active arena. `byte-buf-ref`, `byte-buf-get`, length/capacity inspection, clear, and in-place set are non-allocating. `byte-buf-as-bytes`, `byte-buf-as-mut-bytes`, `str-as-bytes`, `bytes-slice-view`, and `bytes-mut-slice-view` return fixed-length borrowed views; mutable views are exclusive and can update existing bytes without growing the owner. `bytes-to-array`, `bytes-to-string`, and the `byte-buf-from/append-bytes*` helpers are explicit copy boundaries. |
| `byte-buf-builder-*` helpers in `byte_buf_core.tl` | `ByteBufBuilder` construction, reserve, growth, append from arrays or strings, and finish/copy boundaries allocate in the active arena. Length/capacity inspection is non-allocating, and `byte-buf-builder-push` mutates the existing builder through `&mut` unless growth replaces its backing array. The module intentionally omits borrowed `bytes` views and in-place indexed mutation for hot append-only import sites. |
| `arena.*` helpers in `arena.tl` | First-class arena control returns typed `Arena` / `ArenaMark` / `ArenaPhase` wrappers around raw runtime handles. `arena.make` creates an independent ordinary arena, `arena.make-atomic` creates an independent atomic arena, `arena.current` observes the active arena, and `arena.mark` observes the current bump mark. `arena.phase`, `arena.rewind-safe!`, and `arena.destroy-safe!` are accepted only under checker-proven ordinary direct-owner rules. `arena.set!`, `arena.destroy`, and `arena.rewind` can invalidate live heap handles and require `(unsafe ...)`; raw `i64` values do not satisfy those public helper signatures. |
| `args-*` helpers in `args.tl` | Option specs, parse results, occurrence lists, positional `StringVec` storage, diagnostic payloads, and helper substrings allocate in the active arena. Token classification, option lookup, count/presence checks, and value accessors are non-allocating aside from caller-provided owned strings and existing result storage. |
| `json-*` helpers | Parser, lookup, escaping, and JSON number parsing helpers borrow source text or keys. Object lookup compares borrowed keys without allocating. Parsed JSON aggregates, decoded strings, escaped strings, stringified output, float number text, validation copies, vector-builder backing arrays, and final list/member spines allocate owned results in the active arena. Array/object parsing accumulates elements in JSON-local vector builders and converts once to the public list model, preserving source order and first-match duplicate-key lookup. Float conversion is deterministic, finite-only, host-locale independent, and currently accepts up to 300 non-zero significant decimal digits; longer non-zero number text is rejected rather than rounded through an unbounded scratch representation. |
| `(serialize format T)` generated modules in `serialize.tl` | The generic serializer macro itself allocates no runtime storage; it emits calls to the selected format module's hook macros. Generated `encode` allocation behavior is therefore format-owned, while generated `decode` initializes one output aggregate for struct and fixed-array roots/fields before returning `Result.Ok` or `Result.Err`. Dynamic-array roots and fields allocate the decoded output array at the decoded length. Nested struct serializers reuse generated modules and do not copy collection storage beyond decoded array storage and whatever the strategy hooks explicitly allocate. |
| `string-eq`, `string=?`, `string->int` | Equality and integer parsing helpers inspect borrowed string bytes without allocating. Owned `String` places auto-borrow at call sites, and stdlib code that already has `(& r str)` values calls the same public helpers directly. `string->int` keeps the legacy runtime parser rules, including `""`/`"-"` as zero and byte-minus-`'0'` arithmetic for non-digits. |
| `process-*` helpers in `process.tl` / `process_borrowed.tl` | Owned `process.tl` helpers construct process command/output/error aggregates in the active arena. Command builders keep owned `String` parameters because `ProcessCommand`, argv, env, cwd, and stdin fields store owned strings; validators use borrowed text inspection where they do not store inputs. Ordered argv append helpers allocate list nodes. `StringVec` argv helpers accumulate through vector backing storage and convert once to `ProcessStringList`, allocating list nodes while preserving vector order. `ProcessEnvVec` stores env overrides in parallel `StringVec` buffers with an equal-length invariant; append/growth allocate through the underlying vectors, validation checks invalid names and shape, and conversion to `ProcessEnvList` allocates list nodes while preserving vector order and duplicate names. `process_borrowed.tl` exposes lifetime-parameterized `ProcessBorrowedCommand` storage for borrowed executable, argv, cwd, env, and stdin text. Borrowed `output`, `run`, and `start` validate borrowed storage and copy once to owned `ProcessCommand` before the runtime boundary. Borrowed argv and env lists are lifetime-homogeneous; use the owned conversion boundary to join independently scoped text. On Linux and Windows, owned and borrowed process-output/run/start paths execute through `process_runtime.tl`, preserving inherited environment entries, replacing entries named by env overrides, honoring cwd, and feeding string stdin where supported. Unsupported targets return structured errors. |
| `thread.tl` helpers | Thread spawning allocates a small active-arena context, join/result cells, and on Linux a raw worker stack before the OS thread starts. Each worker initializes a fresh per-thread default arena before calling user code. `thread.spawn-string`, `thread.spawn-array-i64`, and `thread.spawn-box-i64` also allocate a fresh atomic arena and one result cell so the joined aggregate storage can safely outlive the worker. Semaphore handles are OS resources and do not allocate TypeLisp heap storage beyond result aggregates. The raw `i64` context/result surface still does not transfer ownership; callers that pass addresses through it remain responsible for synchronization in unsafe code. |
| `random-*` helpers | Construct deterministic RNG state, draw/result aggregates, and compatibility weight-list cons nodes in the active arena. Array and generated `(vector i64)` weighted-index helpers scan existing storage without cons nodes; the legacy list helper copies weights into an active-arena array wrapper before selection. Draws are deterministic from caller-provided seeds and do not read host entropy. `system-seed` reads a platform seed through FFI, normalizes it, and returns a `ResultSystemSeed` aggregate in the active arena; `from-system` constructs and returns a new `RandomState` aggregate in the active arena. |
| `assert-*` helpers in `test.tl` | Non-allocating checks on success; `assert-string-eq` borrows compared text inputs while assertion messages remain owned `String` values for the current `panic` API. |
| `text-buf-*` helpers in `text_buf.tl` / `text_buf_borrowed.tl` | Owned `TextBuf` chunks and rendered strings allocate in the active arena. Append helpers avoid concatenating the accumulated prefix until `text-buf-render`; `text-buf-clear`/`text-buf-reset` return a fresh empty immutable buffer value. `TextBufBorrowed` carries one source lifetime, stores borrowed whole-text chunks, source slices, printable char chunks, and owned chunks without copying at append time. `text-buf-borrowed-append-copy` copies unrelated borrowed chunks into owned active-arena storage before appending, while `text-buf-borrowed-render` copies the ordered borrowed/owned chunks directly into one rendered string at the materialization boundary. |
| `msvc.*` helpers | Non-owning target/tool/version/path inputs are borrowed `str` values. Discovery results store owned executable, PATH, LIB, and INCLUDE strings. PATH, Visual Studio toolset, and Windows SDK candidate scans use `StringVec` storage internally. Some internal path probes copy borrowed paths until the lower-level `io/fs` APIs are fully borrowed. |

The recoverable I/O API maps the runtime's integer status codes into the public
`IoError` model. Common not-found, permission, invalid-path, interrupted, and
directory-read statuses get semantic variants; target-specific or unstable
codes remain available as `IoSystemCode`.

Only the companion modules currently return borrow-typed text inside
reference-typed aggregate results; the runnable stdlib compatibility wrappers
still expose owned `String`/aggregate APIs. No stdlib function mutates a
caller-provided buffer in place. Except for the explicit `stdlib/arena.tl`
manual-control surface, stdlib APIs do not manually reset arenas and should
prefer `with-arena` for scoped reclamation. Source-level `arena.set!`,
`arena.destroy`, and `arena.rewind` require `(unsafe ...)`. `str` is specified as
an immutable borrowed text referent, not a mutable buffer type; those policies
should remain explicit when borrowed strings and mutable buffers are added.

### File-handle API (v1, #1036)

`SPEC.md` §6.4 specifies the v1 file-handle surface that extends these
whole-file helpers with explicit open/close and streaming I/O. The
implementation lands incrementally:

- **#1056** — implemented: opaque `FileHandle`, the `OpenMode` enum
  (`OpenRead`, `OpenWriteTruncate`, `OpenWriteAppend`), `file-open` returning
  `ResultIoFile`, and `file-close`. v1 requires explicit close; move-only
  aggregate semantics are specified in `SPEC.md`, but implicit drop/close still
  waits for scoped cleanup support.
- **#1057** — implemented: `file-read-chunk` returning `ResultIoRead` / `FileRead` (a
  `String` payload plus a sticky EOF flag, mirroring `StdinRead`). Chunk bytes
  allocate in the active arena and stay `String`-typed until a future
  byte-buffer/slice split lands.
- **#1058** — implemented: `file-write` and `file-flush` for write-mode
  handles. `OpenWriteAppend` matches the non-truncating `try-append-file`
  append primitive; Linux uses host append mode and Windows returns
  `IoUnsupported` until native handle support lands.

All handle helpers reuse the existing `IoError` model; mode violations, closed
or invalid handles, and unsupported Windows operations return structured
`IoError` results rather than panicking.

## Importing Stdlib Modules

Stdlib modules are imported explicitly:

```lisp
(import stdlib.arena)
(import stdlib.args)
(import stdlib.array)
(import stdlib.byte_buf)
(import stdlib.env)
(import stdlib.ffi)
(import stdlib.fs)
(import stdlib.hash)
(import stdlib.hashmap)
(import stdlib.io)
(import stdlib.iterator)
(import stdlib.json)
(import stdlib.math)
(import stdlib.msvc)
(import stdlib.process)
(import stdlib.random)
(import stdlib.serialize)
(import stdlib.set)
(import stdlib.sort)
(import stdlib.string)
(import stdlib.test)
(import stdlib.time)
(import stdlib.text_buf)
(import stdlib.text_buf_family)
(import stdlib.vector_slice)
```

For dotted imports under `stdlib.`, the loader first checks whether the
importing source tree provides that module identity locally. If not, configured
stdlib roots are searched by mapping the dotted suffix to a path below the
root. If no configured root provides the module, the compiler uses its
embedded copy of the checked-in stdlib as the final fallback.

That means local project modules take precedence over configured stdlib roots.
Configured stdlib roots take precedence over embedded modules. Configured and
embedded stdlib fallbacks only serve normal dotted suffixes below the root; path
traversal is not part of the dotted import model. When compiling or checking
sources outside the repository tree, prefer passing the repository stdlib
directory explicitly:

```sh
typelisp check path/to/main.tl --stdlib-root /path/to/typelisp/stdlib
typelisp compile path/to/main.tl --stdlib-root /path/to/typelisp/stdlib
typelisp run path/to/main.tl --stdlib-root /path/to/typelisp/stdlib
typelisp test path/to/main.tl --stdlib-root /path/to/typelisp/stdlib
```

For ad-hoc local commands, `TYPELISP_STDLIB_ROOT=/path/to/typelisp/stdlib`
provides an optional fallback root. Explicit `--stdlib-root` values are searched
before that environment fallback, and both are searched before the embedded
stdlib, so scripts and CI should keep passing `--stdlib-root` when they need
reproducible resolution.

Copying or staging `stdlib/` next to an entry source still works because the
loader can resolve dotted `stdlib.*` identities from the local source tree, but
`--stdlib-root` is the canonical way to verify root lookup and override
behavior.

The assertion helpers in `stdlib/test.tl` are also intended for inline
`(test ...)` items. They do not allocate on success; `assert-string-eq` takes
borrowed `str` comparison inputs, while messages remain owned `String` values
because the public `panic` API still takes owned text. Repository CI runs
`scripts/verify-inline-tests.sh`, so inline tests placed under stdlib modules or
fixtures are discovered without a manifest edit.

For stdlib work, inline `(test ...)` items are the default for runnable API
behavior that belongs to one module. Keep `stdlib/tests/` fixtures for
expected-rejection checks, multi-file/import-shape coverage, resolution and
embedded-stdlib behavior, host I/O cases with required stdin/stdout/stderr
contracts, and intentional panic/exit-status checks.

## Adding a Module

1. Add the module under `stdlib/`; a file such as `stdlib/name.tl` infers the
   canonical identity `stdlib.name`.
2. Keep the module self-contained except for explicit dotted import
   dependencies.
3. Include a short header comment with its purpose and required primitives.
4. Add the new top-level `.tl` file to `scripts/verify-stdlib.sh`'s module
   manifest.
5. Add new top-level stdlib `.tl` files to `src/compiler_embedded_stdlib.tl`
   so installed compiler binaries can use them through embedded stdlib
   fallback. Do not add `stdlib/tests/*.tl` fixtures to the embedded payload.
6. Add inline `(test ...)` items next to declarations for source-local runnable
   API behavior; `scripts/verify-inline-tests.sh` discovers them automatically.
7. Add focused fixtures under `stdlib/tests/` only for rejection, multi-file,
   resolution, host I/O stream, or intentional panic/exit-status coverage, and
   list them in `scripts/verify-stdlib.sh`'s runnable or check-only manifest.
   The stdlib verifier runs these fixtures with `--stdlib-root` and rejects
   attempts to re-embed them in `src/compiler_embedded_stdlib.tl`.
8. Document the intended public API coverage in `stdlib/tests/README.md`.
9. Add `;#` module docs, attached `;:` item docs for every public top-level
   declaration, allocation-behavior notes for allocating APIs, an update to the
   arena allocation classification table above, and at least one checked doctest
   example that runs with `--stdlib-root`.
10. Run `scripts/verify-stdlib-docs.sh` to generate Markdown and run doctests
   for every stdlib module.
11. Run `scripts/verify-doc-tests.sh` to confirm the repository-wide doctest
   discovery gate picks up the new documented module without a manifest edit.
12. Run `scripts/verify-inline-tests.sh` if the module adds inline tests.
13. Link user-facing docs or tests to the new module when appropriate.

The verifier intentionally fails when a new top-level `stdlib/*.tl` module or a
new `stdlib/tests/*.tl` fixture is not listed in its corresponding manifest.
That makes every new canonical module and stdlib test an explicit verification
decision.

The documentation verifier discovers every `stdlib/*.tl` file directly and
fails when module docs, item docs for top-level declarations, generated
Markdown, or doctests regress. The repository doctest verifier discovers
documented TypeLisp files under the source and test trees automatically, so new
doctest fences in stdlib modules do not require a separate doctest manifest
update.
