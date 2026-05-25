# Stdlib Test Manifest

`scripts/verify-stdlib.sh` runs the fixtures listed in its
`stdlib_test_manifest` table. Each row maps a fixture path to the expected exit
code, stdout, stderr, and optional stdin. Use `-` for an empty stream,
`literal:<text>` for exact inline text without a trailing newline,
`printf:<escapes>` for printf-style escapes, `host-line:<text>` for one line
using the host executable's newline convention, or a path under this directory
for exact expected output bytes.

Coverage notes:

- `string_edges.tl` covers the public string predicates, trimming helpers,
  replacement paths, and prefix checks, including empty strings, empty needles,
  misses, prefix positions, and replacement edge cases.
- `json_helpers.tl` exercises the JSON data model, list/member helpers, escape
  helpers, parser subroutines, and serializer helpers directly.
- `json_parse_stringify.tl` covers end-to-end parsing and stringifying for
  invalid input, escapes, nesting, arrays, objects, lookup, and number forms.
- `io_edges.tl` covers `IoError` rendering, `try-read-file`,
  `try-write-file`, `try-file-exists?`, `try-append-file`, `read-file-or`,
  `append-file`, and `file-nonempty?` on missing, empty-path, directory-read,
  missing-parent write, empty-file, and existing-file paths without masking host
  I/O failures.
- `io_stdio_lines.tl` covers stdin line wrappers, blank-line vs EOF state,
  stdout/stderr write-line helpers, and stdout flushing with fixture stdin.
- `io_stdio_bytes.tl` covers fixed-byte stdin wrappers, short reads at EOF, and
  zero-byte reads preserving the sticky EOF state.
- `env_api.tl` covers missing, empty, and present environment variables,
  host-separator PATH splitting/joining, and explicit Windows `;` path-list
  behavior.
- `process_api.tl` covers command construction, argv append helpers,
  cwd/stdin/env accessors, invalid-command diagnostics, result/error predicates,
  and unsupported optional execution settings.
- `process_runtime.tl` covers backend process execution for stdout, stderr,
  nonzero status, and failed spawn on Linux, plus the structured unsupported
  result on Windows.
- `text_buf_api.tl` covers empty buffers, repeated appends, char/int append
  helpers, buffer concatenation, clear/reset behavior, and rendering.
- `test_assert_success.tl` covers successful assertion helpers. The
  `test_assert_failure.tl` fixture covers the panic-on-failure path and exact
  caller diagnostic on stderr.
