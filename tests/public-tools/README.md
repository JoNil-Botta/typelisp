# Public Tools Test Fixtures

This directory contains REPL transcript fixtures and LSP JSON-RPC protocol fixtures
that replace the corresponding Rust test cases in `tests/cli.rs`.

## Fixture Format

### REPL Fixtures (`repl/*.txt`)

Each fixture is a plain text file with three sections separated by `---` on its own line:

```
<input lines sent to REPL stdin>
---
<expected stdout (may include glob patterns)>
---
<expected stderr (may include glob patterns)>
```

- Empty expected section means no output is expected on that stream.
- Lines prefixed with `! ` in expected sections are negative assertions (must NOT appear).
- Lines prefixed with `~ ` are substring match (default for non-empty lines).
- Lines prefixed with `= ` are exact line match.
- Exit code is always 0 (success) unless the fixture name starts with `error-`.

### LSP Fixtures (`lsp/*.json` and `lsp/*.sh`)

Each fixture has a `.json` input file and a `.check` assertion file:

- `.json` file: array of JSON-RPC request objects. The runner auto-wraps each with
  `Content-Length` framing.
- `.check` file: list of assertions, one per line:
  - `stdout contains <substring>`
  - `stdout regex <pattern>`
  - `stderr contains <substring>`
  - `stderr exact <text>`
  - `message contains <substring>` — checks any parsed JSON-RPC response message
  - `message count <n>` — total parsed messages
  - `exit <code>`

## Running

From the repository root:

```bash
# Set TYPELISP_BIN, or the script fetches the published stage0 automatically.
scripts/fetch-stage0.sh
TYPELISP_BIN=./target/stage0/typelisp ./scripts/verify-public-tools.sh
```

The REPL and LSP fixtures are exercised by `run-corpus.sh`, which is called by
`verify-public-tools.sh`.

`cli-command-surface.txt` is the explicit command-surface manifest for the
freshly built `src/main.tl` binary in the CI gate. Each row is
`status|command|issue`, where `active` commands must have a smoke assertion in
`scripts/verify-selfhost-cli-build-run.sh`, and `pending` commands must return a
`cli-pending` diagnostic with the listed tracking issue.
