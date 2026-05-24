# Selfhost compiler corpus

A curated corpus of standalone `.tl` programs that exercise the current
self-hosted compiler driver, [`selfhost/compile_smoke.tl`](../compile_smoke.tl),
end to end: source text in, native assembly out, assembled + linked + run.

This is the external-corpus / local-runner slice of the self-hosting effort
(issue #524, covering items 2 & 3 of #520). It is deliberately limited to the
expression subset `compile_smoke.tl` can lower **today** — integer arithmetic,
`let` / multi-binding `let`, `if`, comparisons, `begin`, `set!`, `while`,
`and` / `or` / `not`, `define`, direct calls, and literal-only `print`. It grows
as the backend gaps tracked in #520 close.

## Layout

- `*.tl` — success programs. Each is compiled by the driver, then the emitted
  `.s` is assembled, linked, and run; its exit code (and stdout, if any) is
  asserted.
- `errors/*.tl` — programs the driver must reject. Each must make the driver
  exit non-zero, print a specific diagnostic on stderr, and emit no assembly.

Every program is registered with its expected outcome in
[`scripts/verify-selfhost.sh`](../../scripts/verify-selfhost.sh) (the `ok_manifest`
and `err_manifest` functions). The script fails if a corpus file is added
without a matching manifest entry, so new cases land with an explicit
expectation.

## Running locally

The runner needs the GNU assembler (`as`) and linker (`ld`), so it is Linux
only; it no-ops cleanly on other platforms.

```sh
# Build the stage0 compiler and drive the whole corpus:
./scripts/verify-selfhost.sh

# Or reuse an already-built compiler:
TYPELISP_BIN=./target/release/typelisp ./scripts/verify-selfhost.sh
```

The same step runs in the `integration` CI job. These cases are also exercised
inline by the Rust harness in `tests/integration.rs`; the corpus makes them
reviewable as standalone programs and extendable without touching Rust.
