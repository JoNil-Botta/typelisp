# Public Tools Test Fixtures

This directory contains REPL transcript fixtures and LSP JSON-RPC protocol fixtures
that replace the corresponding Rust test cases in `tests/cli.rs`.

## Fixture Format

REPL fixtures use a `.in` transcript and a `.spec.json` expectation file.
LSP fixtures use a `.in.json` array of request objects (one object per line),
which the runner wraps in byte-counted `Content-Length` frames, and a
`.spec.json` expectation file. A matching `.prep.sh` may prepare the fixture
workspace. Linux-only fixtures live under `selfhost-lsp` or use `.linux.in`.

The line-oriented expectation format supports:

- `exit` (defaults to zero).
- `stdout_contains`, `stdout_not_contains`, `stderr_contains` and
  `stderr_not_contains`: arrays of fixed strings, split into separate patterns
  by decoded newlines; empty patterns are ignored.
- `stdout_exact` and `stderr_exact`: exact bytes, including final newlines.
  On Windows only these exact comparisons strip carriage returns.
- `message_count`: the number of newline-terminated extracted message lines.
- `message_checks`: one object per line. A matching message must satisfy its
  `jsonpath_id`, optional `jsonpath_result: null`, every `raw_contains` and
  `json_contains` needle, and every `raw_not_contains` exclusion. Repeated keys
  intentionally express multiple checks; do not parse them into an object map.
  Needles substitute `${{TMP}}` and `${{TMP_URI}}` with the fixture workspace.

`lib-result-checks.sh` evaluates a case in one process, shared by REPL and LSP.
`test-result-checks.sh` checks passing and failing assertions, ordered error
text, repeated keys, path substitutions and byte/newline boundaries. The
existing public-tool gate runs it before the corpus.

## Running

From the repository root:

```bash
# Set TYPELISP_BIN, or the script fetches the published stage0 automatically.
scripts/fetch-stage0.sh
TYPELISP_BIN=./target/stage0/typelisp ./scripts/verify-public-tools.sh
```

The REPL and LSP fixtures are exercised by `run-corpus.sh`, which is called by
`verify-public-tools.sh`. Run `tests/public-tools/run-corpus.sh lsp
fresh|batch|differential` to select LSP execution. Linux defaults to differential
(fresh sessions compared with one batch process); Windows defaults to batch.
All modes use the same expectations and result checker.

`cli-command-surface.txt` is the explicit command-surface manifest for the
freshly built `src/main.tl` binary in the CI gate. Each row is
`status|command|issue`, where `active` commands must have a smoke assertion in
`scripts/verify-selfhost-cli-build-run.sh`.
