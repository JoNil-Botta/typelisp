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

## Implementation Languages Rule

**Implementation, tooling, tests, and build logic must be written in `sh`
(POSIX shell) or `typelisp` (`.tl`) only.** Rust, C, Python, PowerShell, and any
other programming language are not permitted for those purposes. This formalizes
the self-hosted, no-Rust direction
([#795](https://github.com/JoNil-Botta/typelisp/issues/795)) as an explicit,
enforceable rule (see
[#1171](https://github.com/JoNil-Botta/typelisp/issues/1171)).

Permitted **non-code** (config/markup/data, not implementation languages):
GitHub Actions YAML, JSON / `.manifest` / `.expected` / `.in` / `.contains` test
fixtures, Markdown docs, and `.gitignore` / `.gitattributes`. Generated
artifacts (e.g. `.s`, `.o`) should not be committed.

Path exceptions:

- **`benchmarks/**`** — comparison baselines may be C (and other languages); the
  benchmark harness exists to compare TypeLisp *against* clang-compiled C.
- **`tools/vs-code-extension/**`** — editor-API client code.
- **`scripts/fetch-stage0.ps1`** — Windows PowerShell bootstrap wrapper for
  fetching the published stage0 compiler.

Enforcement is staged (warn-then-enforce, like the lint gate
[#1164](https://github.com/JoNil-Botta/typelisp/issues/1164)): the rule cannot
hard-fail while the Rust stage0 still exists. Rust is retired through the
no-Rust cutover (#795, tracked under
[#666](https://github.com/JoNil-Botta/typelisp/issues/666)); the C `cpuid` probe
through [#1168](https://github.com/JoNil-Botta/typelisp/issues/1168). The
`tests/public-tools/` Python runner was migrated by #1171. The
`scripts/check-implementation-languages.sh` CI allowlist gate honors the path
exceptions above, keeps the current Rust stage0 baselined, and fails on new
unbaselined forbidden-language files.

## No Syntax Aliases Rule

**When you change language syntax, do not add an alias or a second parser path
for the old spelling. Migrate every existing usage to the new syntax and remove
the old form in the same change.**

Keeping the old spelling working "for compatibility" leaves two ways to write
the same thing and lets the old syntax linger indefinitely. A syntax change is
complete only when the new spelling is the *sole* spelling: update `src/`,
`selfhost/`, `stdlib/`, `examples/`, `tests/`, `SPEC.md`, `README.md`, the
editor grammar under `tools/`, and any verification scripts together, so that
`git grep <old-spelling>` returns no production code or syntax. Land the rename
as one converging change rather than an add-then-maybe-migrate-later sequence.

This overrides any "replace **or alias**" allowance in individual feature
issues. See
[#1118](https://github.com/JoNil-Botta/typelisp/issues/1118) for the policy's
origin (the `with-region` → `with-arena` convergence).

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
