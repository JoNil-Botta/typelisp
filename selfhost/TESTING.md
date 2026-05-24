# Selfhost compiler testing

This guide describes the testing convention for compiler-facing TypeLisp code
under `selfhost/`. The self-hosted compiler is still built in layers, so tests
are also layered: keep each case at the lowest layer that proves the behavior,
then add runnable or end-to-end coverage only when that extra boundary matters.

The broader work is tracked by the parity umbrella
[#641](https://github.com/JoNil-Botta/typelisp/issues/641), the selfhost CI
suite gate [#520](https://github.com/JoNil-Botta/typelisp/issues/520), and the
bootstrap/fixpoint gate [#47](https://github.com/JoNil-Botta/typelisp/issues/47).

## Coverage layers

### Module-local self-tests

Put small structural checks next to the module that owns the behavior. These are
usually functions named `*-self-test`, with focused boolean helpers when that
makes the assertion readable.

Current examples include:

- `compiler-parse-error-tests-ok?` and `compiler-parse-smoke` in
  `compiler_parse_core.tl`
- `compiler-symbols-self-test` in `compiler_symbols.tl`
- `compiler-typecheck-self-test` in `compiler_typecheck.tl`
- `compiler-lower-self-test`, `compiler-live-self-test`,
  `compiler-regalloc-self-test`, and `compiler-backend-self-test`
- `compiler-optimize-self-test` plus the pass-specific optimizer self-tests

Prefer small hand-built fixtures and deterministic structural assertions over
large golden strings. A runnable self-test returns `42` on success. Failures
should be specific enough to identify the broken layer; using `panic` with a
short module-prefixed message is normal when a boolean helper fails.

### Smoke drivers

A `*_smoke.tl` file is the runnable wrapper for one or more module-local
self-tests. It should contain little logic: import the module, call the
self-test, and return `42` only when the checks pass. Examples include
`compiler_parse_smoke.tl`, `compiler_lower_smoke.tl`,
`compiler_optimize_smoke.tl`, and `compiler_backend_smoke.tl`.

Use a smoke driver when the module is main-less or when CI needs to compile and
run the module through the TypeLisp executable boundary. If a new smoke driver
imports additional selfhost files, keep the Rust staging lists in sync.

### Rust compile tests

The `tests/tl_*_compile.rs` files are cross-platform proof that stage0 Rust
TypeLisp can compile selfhost sources to assembly. These tests usually assert
that generated assembly has no TODO marker, has exactly one `main` where
expected, and contains important symbols for the module or smoke driver.

Add or update one of these tests when adding a new compiler module, smoke
driver, or required import. If the source should compile or run on Windows, also
update the selfhost source mapping and dependency staging in
`tests/windows_native.rs`.

### Linux integration tests

`tests/integration.rs` contains the heavier Linux-only checks that assemble,
link, and run generated assembly. Use this layer for behavior that only shows up
after execution: exit status, stdout/stderr, diagnostic rendering, deterministic
file output, and import-aware driver behavior.

The integration harness also runs smoke drivers through explicit build cases.
When a smoke driver needs another imported module, add the dependency to the
corresponding staged input list so the Linux integration job exercises the same
import graph reviewers see locally.

### External compiler corpus

The standalone source corpus under `selfhost/tests/` is for programs accepted or
rejected by `selfhost/compile_smoke.tl`. The runner
`scripts/verify-selfhost.sh` builds the smoke compiler once, compiles each
corpus program, and checks the expected exit code, stdout, stderr, or diagnostic.

Each new corpus file must be listed in the script manifest. See
[`selfhost/tests/README.md`](tests/README.md) for the corpus layout and local
runner commands.

### CI expectations

Pull requests get Linux and Windows `cargo test` coverage from the main CI test
jobs. The Linux test job also runs deterministic assembly checks. The separate
integration job builds a release compiler and runs the TypeLisp source format,
stdlib, examples, and selfhost verification scripts.

For a selfhost compiler change, a typical local check is:

```sh
cargo fmt
cargo test --test tl_compiler_parse_compile
cargo test --test tl_compiler_lower_compile
cargo test --test tl_compiler_backend_compile
TYPELISP_BIN=./target/debug/typelisp ./scripts/check-tl-format.sh
TYPELISP_BIN=./target/debug/typelisp ./scripts/verify-selfhost.sh
```

Run the tests that match the layer you touched. On non-Linux platforms, scripts
that require native `as`/`ld` either no-op by design or should be run through a
Linux environment.

## Checklist for new coverage

- Pick the smallest useful layer: module-local assertion, smoke driver, Rust
  compile test, Linux integration test, or external corpus case.
- Add or extend a module-local `*-self-test` for compiler internals that can be
  checked structurally.
- Add or update a `*_smoke.tl` wrapper when the self-test should be executable.
- Update the matching `tests/tl_*_compile.rs` test so the source compiles in
  normal `cargo test`.
- Keep dependency staging in sync for `tests/integration.rs` and
  `tests/windows_native.rs` whenever imports change.
- Use `selfhost/tests/` plus `scripts/verify-selfhost.sh` for source programs
  that should be accepted or rejected by `compile_smoke.tl`.
- Prefer naming conventions and representative examples in docs and comments;
  avoid maintaining long file lists that will go stale.
- Run the focused tests for the layer touched, plus `cargo fmt`.
