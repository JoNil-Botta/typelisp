# Contributing to TypeLisp

Thanks for your interest! This is a learning project — all contributions welcome.

## Development Setup

1. Clone the repo: `git clone https://github.com/JoNil-Botta/typelisp`
2. Fetch the published self-hosted stage0 compiler: `scripts/fetch-stage0.sh`
   (or `powershell -ep Bypass -f scripts\fetch-stage0.ps1` on Windows). It
   installs as `target/stage0/typelisp` (Linux) or `target/stage0/typelisp.exe`
   (Windows).
3. You also need a native toolchain: `as` + `ld` on Linux, or `clang` + MSVC
   `link.exe` + a Windows SDK on Windows, for build/run.
4. Run the verification gate: `scripts/ci-verify.sh`.

TypeLisp is **fully self-hosted**: the compiler compiles itself. There is no
Rust (or other-language) compiler — see the self-perpetuating bootstrap in
[`.github/workflows/bootstrap-stage0.yml`](.github/workflows/bootstrap-stage0.yml)
and the README's stage0 section.

## Zero Dependencies Rule

**TypeLisp has no third-party dependencies.** The only build inputs are the
native assembler/linker toolchain. This keeps the project simple, auditable, and
free from supply-chain risk. If you need functionality that isn't available,
implement it in TypeLisp.

## Implementation Languages Rule

**Implementation, tooling, tests, and build logic must be written in TypeLisp
(`.tl`).** Any other programming language is not permitted for those purposes
unless a path exception below applies. This is the self-hosted direction
([#795](https://github.com/JoNil-Botta/typelisp/issues/795),
[#666](https://github.com/JoNil-Botta/typelisp/issues/666)) as an explicit,
enforced rule.

Permitted **non-code** (config/markup/data, not implementation languages):
GitHub Actions YAML, JSON / `.manifest` / `.expected` / `.in` / `.contains` test
fixtures, Markdown docs, and `.gitignore` / `.gitattributes`. Generated
artifacts (e.g. `.s`, `.o`) should not be committed.

Path exceptions:

- **`scripts/*.sh`** and **`tests/public-tools/*.sh`** - POSIX shell wrappers
  and public-tool corpus harnesses.
- **`scripts/*.ps1`** - Windows PowerShell wrappers and benchmark helpers.
- **`benchmarks/**`** - comparison baselines may be C (and other languages); the
  benchmark harness exists to compare TypeLisp *against* clang-compiled C.
- **`tools/vs-code-extension/**`** - editor-API client code.

The `scripts/check-implementation-languages.sh` CI gate honors the path
exceptions above and **fails on any new forbidden-language file** outside them,
enforcing the TypeLisp-only policy.

## No Syntax Aliases Rule

**When you change language syntax, do not add an alias or a second parser path
for the old spelling. Migrate every existing usage to the new syntax and remove
the old form in the same change.**

Keeping the old spelling working "for compatibility" leaves two ways to write
the same thing and lets the old syntax linger indefinitely. A syntax change is
complete only when the new spelling is the *sole* spelling: update `src/`,
`src/`, `stdlib/`, `examples/`, `tests/`, `SPEC.md`, `README.md`, the
editor grammar under `tools/`, and any verification scripts together, so that
`git grep <old-spelling>` returns no production code or syntax. Land the rename
as one converging change rather than an add-then-maybe-migrate-later sequence.

This overrides any "replace **or alias**" allowance in individual feature
issues. See
[#1118](https://github.com/JoNil-Botta/typelisp/issues/1118) for the policy's
origin (the `with-region` → `with-arena` convergence).

## Before Submitting

Set `TYPELISP_BIN=target/stage0/typelisp` (or `.exe` on Windows) after
`scripts/fetch-stage0.sh`, then:

- `$TYPELISP_BIN fmt --check <files>` — format your TypeLisp source
- `TYPELISP_BIN=$TYPELISP_BIN scripts/check-tl-lint.sh` — fix lint findings
- `scripts/ci-verify.sh` — run the full verification gate CI uses
- For selfhost compiler changes, follow [`src/TESTING.md`](src/TESTING.md)
  when choosing module self-tests, smoke drivers, inline tests, and integration
  coverage.

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

The compiler is written in TypeLisp under [`src/`](selfhost). Key modules:

- `src/lexer.tl` — tokenizes source code
- `src/compiler_parse_core.tl` — builds the AST from tokens
- `src/compiler_typecheck.tl` — type inference and checking
- `src/compiler_lower.tl` — lowering to the 3-address IR
- `src/compiler_optimize.tl` — IR optimization passes
- `src/compiler_backend.tl` — x86_64 code generation
- `src/main.tl` — the unified toolchain CLI (the published stage0 binary)
- `src/compile.tl` — the minimal compile entry point used by the bootstrap

See [`src/TESTING.md`](src/TESTING.md) for the testing conventions.

## Questions?

Open an issue or discussion.
