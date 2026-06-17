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
- `string_edges.tl` covers the public string equality/parsing predicates,
  trimming helpers, replacement paths, and prefix checks, including empty
  strings, empty needles, misses, prefix positions, legacy `string->int` edge
  cases, and replacement edge cases.
- `list_api.tl` covers the monomorphic `StringList` and `StringListBuilder`
  helpers: empty/single lists, count, reverse, append, build-onto order, array
  conversion with count clamping, and `StringVec` bridge round trips.
- `vector_api.tl` covers the generated concrete vector family: `I64Vec`
  compatibility, higher-order `I64Vec` fold/map helpers with named functions
  and scalar-capturing lambdas, `StringVec` growth/mutation/pop/snapshot/reverse
  paths, and a fixture-local generated enum-payload vector witness for nominal
  element metadata.
- `vector_slice_check.tl` covers the lifetime-scoped `I64Slice` view API,
  including vector and array constructors, invalid ranges producing empty views,
  sub-slicing, fallback reads, and explicit array/vector copy boundaries.
  `vector_slice_escape.tl` verifies the checker rejects returning a slice tied
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
- `io_edges.tl` covers `IoError` rendering, `try-read-file`,
  `try-write-file`, `try-file-exists?`, `try-append-file`, `read-file-or`,
  `append-file`, and `file-nonempty?` on missing, empty-path, directory-read,
  missing-parent write, empty-file, and existing-file paths without masking host
  I/O failures.
- `io_file_handle.tl` covers `FileHandle` open/close success, streaming chunk
  reads, streaming writes/flush, zero-byte reads, EOF stickiness, negative
  counts, invalid/read-after-close and mode-mismatch failures, empty-path and
  missing-file open failures, write-truncate writes, write-append writes and
  creation, and the Windows unsupported result.
- `io_stdio_lines.tl` covers stdin line wrappers, blank-line vs EOF state,
  stdout/stderr write-line helpers, and stdout flushing with fixture stdin.
- `io_stdio_bytes.tl` covers fixed-byte stdin wrappers, short reads at EOF, and
  zero-byte reads preserving the sticky EOF state.
- `io_stdio_pipe_short_read.tl` is typechecked like the other witnesses and is
  also run by `scripts/verify-stdlib.sh` through a native pipe to ensure
  positive short pipe reads do not report EOF before all bytes arrive.
- `fs_path_join_many_api.tl` covers the variadic path-join macro for zero,
  single, two, three, four, and duplicate-separator joins.
- `fs_api.tl` covers path joins, dirname/basename/extension helpers, temp-dir
  creation, recoverable cleanup helpers, Linux file/directory rename behavior,
  directory iteration through list and vector wrappers, read-dir split order,
  missing and empty rename paths, and Windows unsupported rename/read-dir
  results.
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
- `sort_api.tl` covers `stdlib/sort.tl` stable in-place insertion sort helpers
  for `I64Vec` and `StringVec`, including empty, single, already sorted,
  reverse sorted, duplicate, negative-number, prefix, and lexicographic string
  cases.
- `sync_api.tl` covers `stdlib/sync.tl` bounded `ChannelI64` creation
  failures, blocking send/recv success paths in a single thread, FIFO
  wraparound, raw handle packing, and resource close. It also covers `MutexI64`
  guard locking, guarded get/set/add, raw handle packing, and resource close.
- `msvc_api.tl` covers pure MSVC discovery helpers with fake temp-directory
  toolset and SDK trees, including newest-usable candidate selection through
  the vector-backed scanners.
- `process_api.tl` covers command construction, argv append helpers,
  cwd/stdin/env accessors, vector-backed env override construction,
  validation, duplicate-name order, list conversion, invalid-command
  diagnostics, result/error predicates, and async start/wait API validation.
- The process borrowed escape fixture verifies the checker rejects returning a
  borrowed command whose text owner is shorter-lived than the declared command
  lifetime.
- `process_runtime.tl` covers backend process execution for stdout, stderr,
  env override propagation through list-backed and vector-backed command
  builders, nonzero status, failed spawn, and async start/wait on Linux, plus
  the structured unsupported async result on Windows.
- `thread_api.tl` covers worker count fallback shape, invalid semaphore
  creation, two native worker threads, semaphore signaling, and join return
  values.
- `time_api.tl` covers `time-unix-ms` positive wall-clock range checks,
  `time-monotonic-ms` non-negative and non-decreasing checks, and structured
  `ResultTimeMs` error/fallback helpers without depending on exact timestamps.
- `text_buf_api.tl` covers empty buffers, repeated appends, char/int append
  helpers, buffer concatenation, clear/reset behavior, and rendering.
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
- `comptime_api.tl` owns inline tests for expression macro operand values,
  variadic `Expr` lists, syntax matching, and generated expression results
  while preserving the explicit `stdlib.comptime` module-alias import shape.
- `core_macros.tl` owns inline tests for zero-, one-, and many-operand
  `and`/`or`, guard macros, bracket-arm `cond` result types, and
  short-circuiting.
- `io.tl` owns inline coverage that bare prelude `and`/`or`/`when`/`unless`
  macros remain available beside a runtime stdlib module.
- `json.tl` owns inline tests for the JSON data model, list/member helpers,
  escape helpers, parser subroutines, deterministic finite f64/f32 number
  conversion, serializer helpers, and end-to-end parse/stringify behavior for
  invalid input, escapes, nesting, arrays, objects, lookup, and number forms.
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
- `string.tl` owns inline tests for the borrowed `str` gate and scoped arena
  string allocation policy, including nested `with-arena` allocation and
  borrowed equality against region-owned values.
- `text_buf.tl` owns inline tests for scoped arena rendering of a program-owned
  text buffer from an inner active arena.
- `ffi.tl` owns inline tests for C string buffers: required byte counts,
  exact-capacity caller-owned copies, trailing NUL writes, too-small buffers,
  interior NUL rejection, and active-arena pointer allocation through
  `ffi-c-string-alloc` / `ffi-cstr`.
- `string_caller_result.tl` owns inline tests for borrowed no-match results,
  owned replacement results, the branch-selecting `string-replace-result`
  helper, and explicit owned materialization.
- `io_caller_result.tl` owns inline tests for `read-file-or-result`
  fallback-borrow and owned-result paths.
- `text_buf_borrowed.tl` owns inline tests for borrowed chunks, owned chunk
  boundaries, copied unrelated borrowed chunks, render, length, and empty
  predicates.
- `process_borrowed.tl` owns inline tests for borrowed executable, argv, cwd,
  env, and stdin fields, validation diagnostics, and explicit conversion to
  owned `ProcessCommand` before the runtime boundary.
