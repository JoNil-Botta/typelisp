# Public Tools Test Fixtures

This directory holds the REPL transcript and LSP JSON-RPC fixtures that
`run-corpus.sh` runs against `typelisp repl` and `typelisp lsp`.

## Fixture Format

Every fixture is an input file plus a `.spec.json` expectation with the same
stem. A `.linux.` infix (`name.linux.in`, `name.linux.spec.json`) limits the
fixture to Linux hosts.

- `repl/*.in` is sent to `typelisp repl` on stdin.
- `lsp/*.in.json` is an array of JSON-RPC messages, one per line; the runner
  adds the byte-counted `Content-Length` framing. An optional `name.prep.sh`
  runs first with `FIXTURE_TMP` and `FIXTURE_TMP_URI` set to the case's
  temporary directory.
- `selfhost-lsp/*.linux.in.json` are framed the same way; `*.linux.in` files
  are raw protocol bytes, for malformed-frame cases.

Inputs and `message_checks` strings may use `${{TMP}}` and `${{TMP_URI}}` for
the case's temporary directory, inside JSON strings. Both expand literally, as
JSON string text, in one pass: spaces, `&`, quotes and non-ASCII bytes need no
care from a fixture. `${{TMP_URI}}` percent-encodes the path the way the server
builds file URIs. A temporary path with a control character or a backslash
(a path separator to `stdlib.fs`) is refused with a diagnostic.

A `.spec.json` is read line by line and may contain:

- `exit`: the expected exit code (default 0);
- `stdout_exact`, `stderr_exact`: the whole stream, byte for byte including
  the final newline; on Windows only these two comparisons ignore carriage
  returns;
- `stdout_contains`, `stdout_not_contains`, `stderr_contains`,
  `stderr_not_contains`: fixed substrings; a decoded newline splits a string
  into separate substrings, and empty ones are ignored. Every string of the
  array is checked, including ones that contain `]`, commas or escaped quotes;
- LSP only: `message_count`, the number of newline-terminated parsed JSON-RPC
  messages, and `message_checks`, one object per line, each of which some
  message must pass: an optional `jsonpath_id` (the message's `id`, matched
  as a whole number, so 1 never selects 10), an
  optional `"jsonpath_result": null`, and `raw_contains`, `raw_not_contains`
  and `json_contains` strings. A key may repeat within one check and every
  occurrence applies, so a check is not read as a JSON object.

`lib-result-checks.sh` checks a case's exit code, streams and messages in one
awk process, for both corpora. It also owns the path handling every stage
shares: placeholder expansion, request framing, file URIs and the
fresh-versus-batch normalization. `test-result-checks.sh` is its self-test
(passing and failing checks, the order of the failure lines, repeated keys,
literal path substitution, UTF-8 request frames, byte and final-newline
edges); `verify-public-tools.sh` runs it before the corpora.

## Running

From the repository root:

```bash
# Set TYPELISP_BIN, or the script fetches the published stage0 automatically.
TYPELISP_BIN=./target/stage0/typelisp ./scripts/verify-public-tools.sh
TYPELISP_BIN=./target/stage0/typelisp tests/public-tools/run-corpus.sh lsp fresh
```

`verify-public-tools.sh` calls `run-corpus.sh` for both corpora.
`run-corpus.sh [repl|lsp] [fresh|batch|differential]` runs one corpus; LSP cases
run one process per case (`fresh`), all cases through one batch process
(`batch`, the Windows default), or both with their results compared
(`differential`, the Linux default). Every mode checks results with the same
expectations and checker.

The command-surface list of the freshly built `src/main.tl` binary, with one
smoke case per command, is `tests/cli/selfhost-surface.cases`.
