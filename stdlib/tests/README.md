# Stdlib Test Manifest

`scripts/verify-stdlib.sh` runs the fixtures listed in its
`stdlib_test_manifest` table and type-checks the fixtures listed in
`stdlib_check_manifest`. Runnable rows map a fixture path to the expected exit
code, stdout, stderr, and optional stdin. Use `-` for an empty stream,
`literal:<text>` for exact inline text without a trailing newline,
`printf:<escapes>` for printf-style escapes, `host-line:<text>` for one line
using the host executable's newline convention, or a path under this directory
for exact expected output bytes. Check-only rows map a fixture path to `pass` or
`fail`; failure rows also name a diagnostic substring expected on stderr.

Coverage notes:

Fixture rows in this directory remain for checks that need a standalone entry
point, exact process I/O, stdin, host fixture setup, negative checker behavior,
or external runtime orchestration. Pure stdlib API coverage that can run through
`typelisp test` lives inline in the owning stdlib module.

- `arena_patterns.tl` covers the standard safe scratch workflows: temporary
  scalar-only work inside `with-arena` and clone-out from a reusable
  first-class scratch arena through `with-escape`. The row remains a runnable
  fixture while its `requires-stage0-symbol:with-escape` constraint is needed.
  The `arena_policy_escape_*.tl` fixtures are check-only negative cases proving
  active-arena stdlib results cannot escape their scoped arena.
- `vector_slice_escape.tl` verifies the checker rejects returning a slice tied
  to a shorter-lived vector.
- `comptime_api.tl` remains a check-only import-shape fixture for expression
  macros whose operand types are written through an explicit
  `stdlib.comptime` module alias; its inline test provides the runnable
  comptime behavior.
- `core_macros_api.tl` remains a check-only import-shape fixture for explicit
  qualified import of the stdlib core macro module as `core`; the runnable core
  macro behavior lives inline in `core_macros.tl` and `io.tl`. The adjacent
  `core_macros_cond_*` check fixtures cover flat-syntax rejection and
  post-expansion `cond` diagnostics.
- `io_stdio_lines.tl` covers stdin line wrappers, blank-line vs EOF state,
  stdout/stderr write-line helpers, and stdout flushing with fixture stdin.
- `io_stdio_bytes.tl` covers fixed-byte stdin wrappers, short reads at EOF, and
  zero-byte reads preserving the sticky EOF state.
- `byte_buf_api.tl` covers the standalone import/build/run path for the owned
  `ByteBuf` core, including array and string append/copy boundaries, binary
  NUL/high-byte storage, snapshot independence, and clear/reuse behavior.
- `io_stdio_pipe_short_read.tl` is typechecked like the other witnesses and is
  also run by `scripts/verify-stdlib.sh` through a native pipe to ensure
  positive short pipe reads do not report EOF before all bytes arrive.
- `stdlib/hashmap.tl` inline tests cover the compatibility `StringI64Map`,
  generated `StringStringMap`, `I64I64Map`, and aggregate key/value map
  families, key descriptor identities, borrowed string-key wrappers,
  update-only, entry-or-insert, live mutable-entry helpers, tombstone reuse,
  growth/rehash, and deterministic bucket-order iteration. The
  `hashmap_mut_borrow_insert_or_update_live.tl` fixture verifies that a live
  map-level mutable borrow rejects insert-or-update. The
  `hashmap_mut_entry_*_live.tl` fixtures verify that live mutable entries reject
  aliasing entries, value borrows, puts, and resizes.
- `stdlib/set.tl` inline tests cover generated `StringSet` and `I64Set`
  families, descriptor identities, borrowed string-key contains/remove wrappers,
  duplicate insert, collision chains, tombstone reuse, growth/rehash, missing
  remove, and deterministic bucket-order iteration.
- `sync_api.tl` keeps the standalone native synchronization runtime coverage:
  blocking send/recv success paths in a single thread, FIFO wraparound, raw
  handle packing, atomic-arena string transfer, resource close, `MutexI64`
  guard locking, guarded get/set/add, close rejection while a guard is live,
  and fail-closed double close. Pure invalid-capacity checks now live inline in
  `stdlib/sync.tl`.
- `process_api.tl` remains a runnable fixture for command-validation paths that
  intentionally call `process-output` / `process-start` and therefore preserve
  the staged `requires-stage0-symbol:tl_process_start,tl_process_wait`
  coverage. Pure command construction, argv/env vector builders, validation
  helpers, duplicate-name order, list conversion, and result/error predicates
  now live inline in `stdlib/process.tl`.
- The process borrowed escape fixture verifies the checker rejects returning a
  borrowed command whose text owner is shorter-lived than the declared command
  lifetime.
- `process_runtime.tl` covers backend process execution for stdout, stderr,
  argv and env propagation through list-backed and vector-backed command
  builders, nonzero status, failed spawn, and async start/wait on Linux, plus
  the structured unsupported async result on Windows.
- `thread_api.tl` keeps the standalone native thread runtime coverage: two
  native worker threads, semaphore signaling, join return values, and the
  checked `String`/array/box join wrappers. Worker-count shape, deterministic
  affinity helper math, and invalid semaphore creation now live inline in
  `stdlib/thread.tl`.
- The borrowed text buffer escape fixture verifies the checker rejects a
  borrowed buffer that would outlive its chunk owner.
- The `string_caller_result.tl` escape fixture verifies the checker rejects a
  helper result that may borrow from a shorter-lived text owner.
- The `io_caller_result.tl` escape fixture verifies the checker rejects
  returning a fallback result whose fallback owner is shorter-lived than the
  declared result lifetime.
- `test_assert_failure.tl` covers the panic-on-failure path and exact caller
  diagnostic on stderr.

Inline stdlib coverage:

- `args.tl` owns inline tests for reusable argv parsing: empty argv,
  positional-only argv, flags before and after positionals, `--`
  end-of-options handling, missing-value and unknown-option diagnostics,
  repeated short/long options, and the intentionally unsupported
  `--name=value` spelling.
- `byte_buf.tl` owns inline tests for the owned mutable byte-buffer core:
  construction and capacity clamping, growth and reserve, push, set/ref/get,
  append from arrays and strings, live range copy, clear/reuse, copy-out
  snapshots, string round trips, and NUL/high-byte binary storage.
- `comptime_api.tl` owns inline tests for expression macro operand values,
  variadic `Expr` lists, syntax matching, and generated expression results
  while preserving the explicit `stdlib.comptime` module-alias import shape.
- `core_macros.tl` owns inline tests for zero-, one-, and many-operand
  `and`/`or`, guard macros, bracket-arm `cond` result types, and
  short-circuiting.
- `io.tl` owns inline coverage that bare prelude `and`/`or`/`when`/`unless`
  macros remain available beside a runtime stdlib module, plus recoverable
  `IoError` rendering, `try-read-file`, `try-write-file`, `try-file-exists?`,
  `try-append-file`, `read-file-or`, `append-file`, `file-nonempty?`, and
  `FileHandle` open/close/read/write/flush/EOF/mode-mismatch behavior.
- `json.tl` owns inline tests for the JSON data model, list/member helpers,
  vector-backed parser builders, escape helpers, parser subroutines,
  deterministic finite f64/f32 number conversion, serializer helpers, and
  end-to-end parse/stringify behavior for invalid input, escapes, nesting,
  arrays, objects, duplicate-key lookup, and number forms.
- `env.tl` owns inline tests for missing, empty, and present environment
  variables, host-separator PATH splitting/joining, vector-backed PATH
  split/list/join helpers, and explicit Windows `;` path-list behavior. The
  inline-test verifier sets the `TYPELISP_STDLIB_TEST_*` environment variables
  used by this coverage.
- `random.tl` owns inline tests for deterministic seed normalization and
  MINSTD sequences, bounded draws, invalid bounds, list/array/vector
  weighted-index edge cases, zero-weight skipping, storage parity, stable picks
  for fixed seeds, and system-seed result payloads.
- `math.tl` owns inline tests for the pure scalar helpers for `i64` and `f64`:
  negative/zero/positive absolute values and sign predicates, min/max order,
  clamp low/high/inside cases, reversed bounds, and explicit signed-min
  fallback behavior for integer abs.
- `hash.tl` owns inline tests for stable deterministic hashes,
  equal-values-same-hash checks, primitive key equality predicates, known
  collision behavior, hash range normalization, and string edge cases.
- `queue.tl` owns inline tests for the growable `i64` queue/deque API:
  capacity clamping, push/pop from both ends, fallback reads, wraparound
  growth, reuse after draining, and explicit empty-pop results.
- `test.tl` owns inline tests for successful assertion helpers, including the
  borrowed `assert-string-eq` path with explicit borrows.
- `arena.tl` owns inline tests for first-class arena helpers, including safe
  handle/mark observation and unsafe switch, rewind, and destroy calls.
- `string.tl` owns inline tests for the borrowed `str` gate, scoped arena
  string allocation policy, public equality/parsing predicates, trimming
  helpers, replacement paths, prefix checks, borrowed/owned substring helpers,
  and legacy `string->int` / `int->string` edge cases.
- `str_cat.tl` owns inline tests for empty, single, two-operand, many-operand,
  variable-operand, nested `str-cat` expansion, generated helper hygiene, and
  declaration-family ordering beside macro expansion.
- `text_buf.tl` owns inline tests for scoped arena rendering of a program-owned
  text buffer from an inner active arena, empty buffers, repeated appends,
  char/int append helpers, buffer concatenation, clear/reset behavior, and
  rendering.
- `list.tl` owns inline tests for the monomorphic `StringList` and
  `StringListBuilder` helpers: empty/single lists, count, reverse, append,
  build-onto order, array conversion with count clamping, and `StringVec`
  bridge round trips.
- `vector.tl` owns inline tests for the generated concrete vector family:
  `I64Vec` compatibility, higher-order `I64Vec` fold/map helpers with named
  functions and scalar-capturing lambdas, `StringVec`
  growth/mutation/pop/snapshot/reverse paths, and fixture-local generated
  enum/struct vector witnesses for nominal element metadata.
- `vector_slice.tl` owns inline tests for the lifetime-scoped `I64Slice` view
  API, including vector and array constructors, invalid ranges producing empty
  views, sub-slicing, fallback reads, and explicit array/vector copy
  boundaries.
- `sort.tl` owns inline tests for stable in-place insertion sort helpers for
  `I64Vec` and `StringVec`, including empty, single, already sorted, reverse
  sorted, duplicate, negative-number, prefix, and lexicographic string cases.
- `ffi.tl` owns inline tests for C string buffers: required byte counts,
  exact-capacity caller-owned copies, trailing NUL writes, too-small buffers,
  interior NUL rejection, and active-arena pointer allocation through
  `ffi-c-string-alloc` / `ffi-cstr`.
- `fs.tl` owns inline tests for variadic path joins, dirname/basename/extension
  helpers, path normalization, safe relative paths, temp-dir creation,
  recoverable cleanup helpers, Linux file/directory rename behavior, directory
  iteration through list and vector wrappers, read-dir split order, metadata
  helpers, current directory helpers, and Windows rename coverage.
- `string_caller_result.tl` owns inline tests for borrowed no-match results,
  owned replacement results, the branch-selecting `string-replace-result`
  helper, and explicit owned materialization.
- `io_caller_result.tl` owns inline tests for `read-file-or-result`
  fallback-borrow and owned-result paths.
- `text_buf_borrowed.tl` owns inline tests for borrowed chunks, owned chunk
  boundaries, copied unrelated borrowed chunks, shared render materialization,
  length, and empty predicates.
- `process_borrowed.tl` owns inline tests for borrowed executable, argv, cwd,
  env, and stdin fields, validation diagnostics, and explicit conversion to
  owned `ProcessCommand` before the runtime boundary.
- `process.tl` owns inline tests for owned command construction, argv append
  helpers, vector-backed argv conversion/builders, cwd/stdin/env accessors,
  vector-backed env override construction, validation, duplicate-name order,
  list conversion, and result/error predicates.
- `sync.tl` owns inline tests for invalid bounded channel capacities and raw
  handle field-count constants. Native blocking send/recv and mutex behavior
  remains in `sync_api.tl`.
- `thread.tl` owns inline tests for worker-count shape, deterministic affinity
  helper math, and invalid semaphore creation. Native spawn/join behavior
  remains in `thread_api.tl`.
- `cpu.tl` owns inline tests for host-independent CPUID/XGETBV SIMD detection
  relationships.
- `profile.tl` owns inline tests for monotonic timestamp shape and allocator
  counter monotonicity around an observable allocation.
- `time.tl` owns inline tests for Unix wall-clock range, monotonic timestamp
  shape, and structured `ResultTimeMs` error/fallback helpers.
- `msvc.tl` owns inline tests for pure MSVC discovery helpers with fake
  temp-directory toolset and SDK trees, including newest-usable candidate
  selection through the vector-backed scanners.
