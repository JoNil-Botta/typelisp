# Public Tools No-Rust Test Fixtures

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
# Requires TYPELISP_BIN or builds release compiler
cargo build --release
TYPELISP_BIN=./target/release/typelisp ./scripts/verify-public-tools.sh
```

The REPL and LSP fixtures are exercised by the runner embedded in
`verify-public-tools.sh`.
