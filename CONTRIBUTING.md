# Contributing to TypeLisp

Thanks for your interest! This is a learning project — all contributions welcome.

## Development Setup

1. Install [Rust](https://rustup.rs/) (latest stable)
2. Clone the repo: `git clone https://github.com/JoNil-Botta/typelisp`
3. Build: `cargo build`
4. Run tests: `cargo test`

## Zero Dependencies Rule

**TypeLisp uses only Rust `std`. No third-party crates allowed.**

This keeps the project simple, auditable, and free from supply-chain risk. If you need functionality that isn't in std, implement it.

## Selfhost-First Rule

New compiler, tooling, runtime, and stdlib feature surface should land in
TypeLisp-owned paths first: `selfhost/`, `stdlib/`, TypeLisp fixtures, or
verification scripts. Do not add new Rust-owned feature surface unless the PR is
explicitly tied to a no-Rust migration issue or includes the paired TypeLisp
implementation path.

This policy supports the self-hosting tracker
[#666](https://github.com/JoNil-Botta/typelisp/issues/666) and final Rust
cutover issue [#795](https://github.com/JoNil-Botta/typelisp/issues/795).

Acceptable Rust exceptions are:

- Deleting Rust as TypeLisp coverage replaces it.
- Keeping stage0 alive temporarily while a selfhost replacement lands.
- Adding parity tests while the paired TypeLisp implementation or no-Rust
  harness is being introduced.
- Changing Rust only to route behavior into selfhost or stdlib code.

When a PR changes Rust-owned files such as `src/**/*.rs`, `tests/**/*.rs`,
`tools/**/*.rs`, `Cargo.toml`, or `Cargo.lock`, fill in the PR template's
`Selfhost-Guardrail:` line with either the paired `selfhost/...` or `stdlib/...`
path, or the temporary bootstrap/migration reason and issue link.

## Before Submitting

- `cargo fmt` — format your code
- `cargo clippy` — fix warnings
- `cargo test` — ensure tests pass
- `cargo check` — ensure zero compiler warnings (CI will fail on warnings)
- Verify `Cargo.toml` has no `[dependencies]` or `[dev-dependencies]` sections (CI will fail if any are present)
- For selfhost compiler changes, follow [`selfhost/TESTING.md`](selfhost/TESTING.md)
  when choosing module self-tests, smoke drivers, Rust compile tests, and
  integration coverage.

## Picking Work

- Check [open issues](https://github.com/JoNil-Botta/typelisp/issues)
- Issues labeled [`good-first-issue`](https://github.com/JoNil-Botta/typelisp/labels/good-first-issue) are great starting points
- Comment on an issue before starting so we don't duplicate effort

## PR Process

1. Fork / branch from `main`
2. Make focused changes
3. Add tests for new functionality
4. Open a PR with a clear description
5. CI must pass before merge

## Architecture Notes

- `src/lexer.rs` — tokenizes source code
- `src/parser.rs` — builds AST from tokens
- `src/ast.rs` — AST data structures
- `src/types.rs` — type system
- `src/typechecker.rs` — Hindley-Milner-ish type inference
- `src/ir.rs` — 3-address intermediate representation
- `src/optimizer.rs` — IR optimization passes
- `src/backend/` — x86_64 code generation
- `src/runtime/` — minimal runtime (alloc, print, panic)

## Questions?

Open an issue or discussion.
