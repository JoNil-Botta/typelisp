# Stdlib Test Manifest

`scripts/verify-stdlib.sh` runs the fixtures listed in its
`stdlib_test_manifest` table. Each row maps a fixture path to the expected exit
code, stdout, and stderr. Use `-` for an empty stream, `literal:<text>` for an
exact inline stream without a trailing newline, or a path under this directory
for exact expected output bytes.

Coverage notes:

- `string_edges.tl` covers the public string predicates, trimming helpers,
  replacement paths, and prefix checks, including empty strings, empty needles,
  misses, prefix positions, and replacement edge cases.
- `json_helpers.tl` exercises the JSON data model, list/member helpers, escape
  helpers, parser subroutines, and serializer helpers directly.
- `json_parse_stringify.tl` covers end-to-end parsing and stringifying for
  invalid input, escapes, nesting, arrays, objects, lookup, and number forms.
- `io_edges.tl` covers `read-file-or`, `append-file`, and `file-nonempty?` on
  missing, empty, and existing files without masking host I/O failures.
- `env_api.tl` covers missing, empty, and present environment variables,
  host-separator PATH splitting/joining, and explicit Windows `;` path-list
  behavior.
- `process_api.tl` covers command construction, argv/cwd/stdin/env accessors,
  argv/env counts, command validation diagnostics, and the current unsupported
  execution result.
- `test_assert_success.tl` covers successful assertion helpers. The
  `test_assert_failure.tl` fixture covers the panic-on-failure path and exact
  caller diagnostic on stderr.
