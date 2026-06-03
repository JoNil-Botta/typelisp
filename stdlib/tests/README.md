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

- `arena_policy.tl` exercises stdlib allocating APIs inside nested scoped
  arenas. The `arena_policy_escape_*.tl` fixtures are check-only negative cases
  proving active-arena stdlib results cannot escape their scoped arena.
- `string_edges.tl` covers the public string predicates, trimming helpers,
  replacement paths, and prefix checks, including empty strings, empty needles,
  misses, prefix positions, and replacement edge cases.
- `json_helpers.tl` exercises the JSON data model, list/member helpers, escape
  helpers, parser subroutines, and serializer helpers directly.
- `json_parse_stringify.tl` covers end-to-end parsing and stringifying for
  invalid input, escapes, nesting, arrays, objects, lookup, and number forms.
- `list_api.tl` covers the monomorphic `StringList` and `StringListBuilder`
  helpers: empty/single lists, count, reverse, append, build-onto order, and
  array conversion with count clamping.
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
- `env_api.tl` covers missing, empty, and present environment variables,
  host-separator PATH splitting/joining, and explicit Windows `;` path-list
  behavior.
- `ffi_api.tl` covers caller-owned C string buffers: required byte counts,
  exact-capacity copies, trailing NUL writes, too-small buffers, and interior
  NUL rejection using an explicitly unsafe test-only string fixture.
- `fs_api.tl` covers path joins, dirname/basename/extension helpers, temp-dir
  creation, recoverable cleanup helpers, Linux file/directory rename behavior,
  missing and empty rename paths, and the Windows unsupported rename result.
- `hash_api.tl` covers stable deterministic hashes, equal-values-same-hash
  checks, primitive key equality predicates, known collision behavior, hash
  range normalization, and string edge cases.
- `process_api.tl` covers command construction, argv append helpers,
  cwd/stdin/env accessors, invalid-command diagnostics, result/error predicates,
  and unsupported optional execution settings.
- `process_runtime.tl` covers backend process execution for stdout, stderr,
  nonzero status, and failed spawn on Linux, plus the structured unsupported
  result on Windows.
- `random_api.tl` covers deterministic seed normalization and MINSTD sequences,
  bounded draws, invalid bounds, weighted-index edge cases, zero-weight
  skipping, and stable picks for fixed seeds.
- `text_buf_api.tl` covers empty buffers, repeated appends, char/int append
  helpers, buffer concatenation, clear/reset behavior, and rendering.
- `visual_studio_api.tl` covers the SetupConfiguration stdlib data model,
  instance/package list helpers, result/error predicates, and the runtime
  success/error result shape.
- `msvc_api.tl` covers MSVC tool result helpers, setup path assembly, numeric
  setup-version ordering, and on Windows running discovered `link.exe /?`.
- `test_assert_success.tl` covers successful assertion helpers. The
  `test_assert_failure.tl` fixture covers the panic-on-failure path and exact
  caller diagnostic on stderr.
