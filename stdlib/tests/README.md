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
  first-class scratch arena through `with-escape`. It runs as a normal runnable
  fixture. The `arena_policy_escape_*.tl` fixtures are check-only negative cases
  proving active-arena stdlib results cannot escape their scoped arena.
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
  `ByteBuf` core, including construction and capacity clamping, growth and
  reserve, push, set/ref/get, array/string/borrowed-bytes append and copy
  boundaries, borrowed and mutable byte views, binary NUL/high-byte storage,
  snapshot independence, string round trips, and clear/reuse behavior.
- `byte_buf_core_api.tl` covers the narrow append-only builder import path used
  by hot compiler/runtime modules, including reserve, push, array and string
  append, binary NUL/high-byte preservation, and explicit array/string finish
  boundaries.
- `io_stdio_pipe_short_read.tl` is typechecked like the other witnesses and is
  also run by `scripts/verify-stdlib.sh` through a native pipe to ensure
  positive short pipe reads do not report EOF before all bytes arrive.
- `stdlib/hashmap.tl` inline tests cover generated String/i64, String/String,
  i64/i64, and aggregate key/value hashmap modules, key descriptor identities,
  borrowed string-key wrappers,
  update-only, entry-or-insert, live mutable-entry helpers, tombstone reuse,
  growth/rehash, and deterministic bucket-order iteration. The
  `hashmap_mut_borrow_insert_or_update_live.tl` fixture verifies that a live
  map-level mutable borrow rejects insert-or-update. The
  `hashmap_mut_entry_*_live.tl` fixtures verify that live mutable entries reject
  aliasing entries, value borrows, puts, and resizes. The
  `hashmap_macro_*_live.tl` fixtures verify the generated module wrappers keep
  the same borrowed-value and mutable-entry aliasing policy.
- `stdlib/set.tl` inline tests cover generated `(set String)` and `(set i64)`
  modules, borrowed string-key contains/remove wrappers, duplicate insert,
  collision chains, tombstone reuse, growth/rehash, missing remove,
  deterministic bucket-order iteration, and duplicate macro-request type
  identity.
- `sync_api.tl` keeps the standalone native synchronization runtime coverage:
  blocking send/recv success paths in a single thread, FIFO wraparound, raw
  handle packing, atomic-arena string transfer, resource close, generated
  `mutex_i64.Mutex` guard locking, guarded get/set/add, close rejection while a guard is live,
  and fail-closed double close. Pure invalid-capacity checks now live inline in
  `stdlib/sync.tl`.
- `process_api.tl` remains a runnable fixture for command-validation paths that
  intentionally call `output` / `start`. Pure command construction, argv/env
  vector builders, validation helpers, duplicate-name order, list conversion,
  and result/error predicates now live inline in `stdlib/process.tl`.
- The process borrowed escape fixture verifies the checker rejects returning a
  borrowed command whose text owner is shorter-lived than the declared command
  lifetime.
- `process_runtime.tl` covers backend process execution for stdout, argv and
  env propagation through list-backed and vector-backed command builders,
  nonzero status, failed spawn, and async start/wait on Linux, plus the
  structured unsupported async result on Windows. `process_runtime_stderr.tl`
  separately covers runtime-backed stderr extraction through the public
  one-pass result helper.
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
- `test_assert_failure.tl` covers the panic-on-failure path and exact caller,
  expected-value, and actual-value diagnostic on stderr.

Inline stdlib coverage:

- `args_api.tl` owns standalone tests for reusable argv parsing: empty argv,
  positional-only argv, flags before and after positionals, `--`
  end-of-options handling, missing-value and unknown-option diagnostics,
  repeated short/long options, and the intentionally unsupported
  `--name=value` spelling.
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
- `env_api.tl` owns standalone tests for missing, empty, and present environment
  variables, host-separator PATH splitting/joining, vector-backed PATH
  split/list/join helpers, and explicit Windows `;` path-list behavior. The
  inline-test verifier sets the `TYPELISP_STDLIB_TEST_*` environment variables
  used by this coverage.
- `random.tl` owns inline tests for deterministic seed normalization and
  MINSTD sequences, bounded draws, invalid bounds, list/array/vector
  weighted-index edge cases, zero-weight skipping, storage parity, stable picks
  for fixed seeds, and system-seed result payloads.
- `math.tl` owns inline tests for the pure scalar helpers for `i64`, `f64`,
  and `f32`: negative/zero/positive absolute values, the generic float `abs`
  macro, sign predicates, min/max order, clamp low/high/inside cases, reversed
  bounds, explicit signed-min fallback behavior for integer abs, exact float
  bit round trips (including NaN payloads and both zeros), classification,
  copy-sign, and `scalbn` normal/subnormal/tie-to-even/overflow behavior.
  `tests/integration/stdlib_math_ieee.tl` runs the foundation natively on both
  Linux and Windows.
- `hash.tl` owns inline tests for stable deterministic hashes,
  equal-values-same-hash checks, primitive key equality predicates, known
  collision behavior, hash range normalization, and string edge cases.
- `queue.tl` owns inline tests for the generated `(deque i64)` module API:
  capacity clamping, push/pop from both ends through `&mut`, fallback reads,
  wraparound growth, reuse after draining, duplicate generated-module imports,
  and explicit empty-pop results.
- `test.tl` owns inline tests for successful assertion helpers, including the
  borrowed `assert-string-eq` path with explicit borrows.
- `arena.tl` owns inline tests for first-class arena helpers, including safe
  handle/mark observation and unsafe switch, rewind, and destroy calls.
- `string.tl` owns inline tests for the borrowed `str` gate, scoped arena
  string allocation policy, public equality/parsing predicates, trimming
  helpers, replacement paths, prefix checks, borrowed/owned substring helpers,
  and legacy `string->int` / `int->string` edge cases.
- `str_cat.tl` owns inline tests for empty, single, two-operand, many-operand,
  variable-operand, nested `str-cat` expansion, and generated helper hygiene.
  `tests/inline/str_cat_hashmap_declaration_ordering.tl` keeps the declaration-
  family ordering check beside a generated hashmap module.
- `format_api.tl` covers literal placeholders, escaped braces, and String,
  integer, boolean, char, and float formatting; `comptime_string_literal_reject.tl`
  keeps non-literal syntax inspection rejected at macro expansion. The
  `format_*_reject.tl` fixtures cover non-literal templates, unsupported
  specifiers, and both placeholder-count mismatches.
- `text_buf.tl` owns inline tests for scoped arena rendering of a program-owned
  text buffer from an inner active arena, empty buffers, repeated appends,
  char/int append helpers, buffer concatenation, clear/reset behavior, and
  rendering.
- `vector_api.tl` covers generated scalar, String, and aggregate vector modules,
  including shared/mutable iterator modes, growth, mutation, pop, snapshot,
  reversal, and value containment.
- `vector_slice.tl` owns inline tests for the lifetime-scoped `(slice i64)`
  generated module API, including vector and array constructors, invalid ranges
  producing empty views, sub-slicing, fallback reads, value-threaded iteration,
  duplicate module-macro imports, and explicit array/vector copy boundaries.
- `sort.tl` owns inline tests for generated stable hybrid merge sort over
  `(vector T)` modules, including scalar, String, and aggregate comparator
  cases, repeated generation deduplication, empty, single, already sorted,
  reverse sorted, duplicate, negative-number, prefix, lexicographic string,
  large non-power-of-two input, a subquadratic comparison ceiling, and stable
  equal-key ordering within and across merged runs.
- `ffi.tl` owns inline tests for C string buffers: required byte counts,
  exact-capacity caller-owned copies, trailing NUL writes, too-small buffers,
  interior NUL rejection, and active-arena pointer allocation through
  `ffi-c-string-alloc` / `ffi-cstr`.
- `fs.tl` owns inline tests for variadic path joins.
- `fs_api.tl` owns standalone tests for dirname/basename/extension helpers,
  path normalization, safe relative paths, temp-dir creation, recoverable
  cleanup helpers, Linux file/directory rename behavior, directory iteration
  through list and vector wrappers, read-dir split order, metadata helpers,
  current directory helpers, and Windows rename coverage.
- `string_caller_result.tl` owns inline tests for borrowed no-match results,
  owned replacement results, the branch-selecting `string-replace-result`
  helper, and explicit owned materialization.
- `io_caller_result.tl` owns inline tests for `read-file-or-result`
  fallback-borrow and owned-result paths.
- `text_buf_borrowed.tl` owns inline tests for borrowed chunks, owned chunk
  boundaries, copied unrelated borrowed chunks, shared render materialization,
  length, and empty predicates.
- `process_borrowed.tl` owns inline tests for borrowed executable, argv, cwd,
  env, and stdin fields, ordered borrowed argv/env append helpers, duplicate env
  override order, validation diagnostics, and explicit conversion to owned
  `ProcessCommand` before the runtime boundary.
- `process_api.tl` owns standalone tests for owned command construction, argv
  append helpers, vector-backed argv conversion/builders, cwd/stdin/env
  accessors, vector-backed env override construction, validation,
  duplicate-name order, list conversion, and result/error predicates.
- `sync.tl` owns inline tests for invalid bounded channel capacities and raw
  handle field-count constants. Native blocking send/recv, generated
  `(channel i64)` module use, duplicate module identity, and mutex behavior
  remain in `sync_api.tl`.
- `thread.tl` owns inline tests for worker-count shape, deterministic affinity
  helper math, and invalid semaphore creation. Native spawn/join behavior
  remains in `thread_api.tl`.
- `cpu.tl` owns inline tests for host-independent CPUID/XGETBV SIMD detection
  relationships.
- `profile.tl` owns inline tests for monotonic timestamp shape and allocator
  counter monotonicity around an observable allocation.
- `time.tl` owns inline tests for Unix wall-clock range, monotonic timestamp
  shape, and structured `ResultTimeMs` error/fallback helpers.
- `msvc_api.tl` owns standalone tests for pure MSVC discovery helpers with
  fake temp-directory toolset and SDK trees, including newest-usable candidate
  selection through the vector-backed scanners.
