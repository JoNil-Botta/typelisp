# Selfhost compiler testing

This guide describes the testing convention for compiler-facing TypeLisp code
under `selfhost/`. The self-hosted compiler is still built in layers, so tests
are also layered: keep each case at the lowest layer that proves the behavior,
then add runnable or end-to-end coverage only when that extra boundary matters.
The Rust harness replacement map lives in
[`RUST_TEST_COVERAGE.md`](RUST_TEST_COVERAGE.md).

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

### Inline tests

Top-level `(test name body...)` items are source-owned executable checks. Normal
`check`, `compile`, `build`, and `run` ignore them. `typelisp test <file.tl>`
loads the import graph, turns tests into private unit-returning functions,
skips any production `main`, generates a test-owned `main`, and runs the
resulting executable. `typelisp test --check <file.tl>` type-checks the
generated harness without assembling or linking.

Use inline tests for behavior that naturally belongs next to the declarations
under test. Import `stdlib/test.tl` for assertions such as `assert-i64-eq`.
Keep smoke drivers for existing compiler-module self-tests until those modules
are intentionally migrated.

[`../scripts/verify-inline-tests.sh`](../scripts/verify-inline-tests.sh)
auto-discovers top-level inline tests under `selfhost/`, `stdlib/`, `tools/`,
`tests/integration/`, `tests/inline/`, and `examples/`. It runs
`typelisp test --check` first, then `typelisp test`, so malformed, untyped,
unbuildable, and failing inline tests all fail CI without a hand-maintained
manifest update.

### Temporary Rust compile tests

The `tests/tl_*_compile.rs` files are temporary cross-platform proof that
stage0 Rust TypeLisp can compile selfhost sources to assembly. These tests
usually assert that generated assembly has no TODO marker, has exactly one
`main` where expected, and contains important symbols for the module or smoke
driver. They remain useful while Cargo is still the required CI path, but every
Rust test file must have an explicit no-Rust replacement entry in
[`RUST_TEST_COVERAGE.md`](RUST_TEST_COVERAGE.md).

Add or update one of these tests when adding a new compiler module, smoke
driver, or required import only as a temporary bridge. The same PR must update
the replacement map with the planned selfhost/script coverage or link a
follow-up issue. If the source should compile or run on Windows, also update
`tests/integration/native-windows.manifest` or the Windows backend fixture checks
in `scripts/verify-integration.sh`.

### Selfhost compile manifest

The no-Rust replacement for compile/symbol smoke coverage is
[`compile_manifest.txt`](compile_manifest.txt), checked by
[`../scripts/verify-selfhost-compile-manifest.sh`](../scripts/verify-selfhost-compile-manifest.sh).
The runner compiles each manifest case with an already-built TypeLisp compiler,
rejects generated `# TODO` assembly, applies the case's `main:` label policy,
and checks representative symbol/literal markers in the emitted assembly.
By default those markers are checked in `stage0` mode, preserving the exact
Rust-stage0 symbol coverage used by the reference `Test` jobs. The Linux
no-Rust capability tier also runs the same manifest through
`scripts/stage1-typelisp-wrapper.sh` with
`TYPELISP_COMPILE_MANIFEST_EXPECTATION_MODE=stage1`; in that mode `_tl_foo`
symbol markers also accept the selfhost compiler's module-qualified
`_tl_<module>_u2etl_colon_colonfoo` labels without changing the manifest list.
Use `requires-stage0-mode|<reason>` only for a case that must remain seed-only
for a named blocker such as the current #1437 stage1->stage2 resource limit.

Every top-level `selfhost/*.tl` file must appear as a manifest `case` or a
`decision` line. This makes new modules and smoke drivers fail CI until they
have an explicit compile-coverage decision. Staged cases cover integration
drivers whose imports need temporary sibling names, such as the text buffer and
symbol-table drivers.

### No-Rust replacement policy

New behavior should first get TypeLisp-owned coverage: a module-local self-test,
a smoke driver, a corpus fixture, or a shell/script runner that uses an existing
TypeLisp compiler artifact. Add Rust tests only when they are explicitly
temporary stage0 reference coverage, and record the deletion path in the
coverage map.

### Published stage0 artifact

After each merge to `main`, the `Bootstrap Stage0` workflow publishes Linux and
Windows compiler assets to the `stage0-latest` release and to an immutable
`stage0-*` release. Fetch the compiler with:

```sh
scripts/fetch-stage0.sh
TYPELISP_BIN=./target/stage0/typelisp ./scripts/verify-selfhost.sh
```

Use `scripts/fetch-stage0.sh <stage0-tag>` to pin an immutable artifact. The
script downloads the host platform asset, verifies the file is non-empty,
checks `SHA256SUMS` when the release provides it, and installs the command under
`target/stage0/`. On Linux it first tries the versioned
`typelisp-stage0-linux-bundle.tar.gz` asset, validates its
`STAGE0_BUNDLE` manifest and required wrapper/runtime paths, then installs the
bundle so the command remains `target/stage0/typelisp`. Older releases without
the bundle continue to install the legacy single-file `typelisp-stage0-linux`
asset. The script uses release asset URLs instead of fetching git tags, so the
mutable `stage0-latest` tag cannot be stale or clobber a local tag.

The bundled Linux stage0 asset is created with:

```sh
cargo build --release
scripts/stage-linux-stage0-bundle.sh target/release/typelisp typelisp-stage0-linux-bundle.tar.gz
```

The archive contains `STAGE0_BUNDLE`, a relocatable root `typelisp` launcher,
`scripts/stage1-typelisp-wrapper.sh`, the TypeLisp-built stage1 compiler under
`lib/stage1/`, prebuilt stage1 doc/build/repl drivers, and the `selfhost/` and
`stdlib/` trees needed by the wrapper. Release `SHA256SUMS` covers the exact
archive that `fetch-stage0` downloads.

The complete local no-Rust gate is:

```sh
scripts/verify-no-rust-stage0.sh
```

That wrapper fetches `stage0-latest` when `TYPELISP_BIN` is unset and treats it
as the seed compiler. It installs failing `cargo` and `rustc` shims in `PATH` so
the gate cannot silently fall back to Rust. On Linux it first runs
the stage1-build path in `check-bootstrap-fixpoint.sh` with the seed compiler,
then routes stage1 capability gates through `scripts/stage1-typelisp-wrapper.sh`.
The raw stage1 compiler accepts the public `typelisp compile` dispatcher form
and keeps the private direct file form used by bootstrap scripts. The wrapper
adds `typelisp doc` and a no-Rust Linux host-action executor for source build/run
and scratch assembly plans. Full public CLI gates still use the seed compiler
until every public-tool exception is ported to the wrapper. On Windows it uses
the seed compiler for host-supported gates, then runs the native MSVC
`link.exe` build/run smoke and the full stage2/stage3 Windows fixpoint when the
seed has the required staged runtime symbols.
The scripts that still run `cargo build --release` when `TYPELISP_BIN` is unset
keep that path as a local fallback only until #795 removes the Rust-owned stage0
dependency.

`scripts/check-bootstrap-fixpoint.sh` is host-sensitive. Linux uses the existing
`as` plus `ld` path and compares Linux `stage2.s` with `stage3.s`. Git
Bash/MSYS/Cygwin on Windows emits `windows-x86_64` assembly, assembles each
stage with `clang --target=x86_64-pc-windows-msvc -c`, links `stage1.exe` and
`stage2.exe` with MSVC `link.exe`, runs both generated compilers, and compares
the Windows `stage2.s` and `stage3.s` outputs. Local Windows prerequisites are
Clang, Visual Studio/MSVC `link.exe`, and a Windows SDK; set
`TYPELISP_WINDOWS_CLANG` or `TYPELISP_WINDOWS_LINK` to override discovery.

Run it from Git Bash with:

```sh
scripts/fetch-stage0.sh
scripts/check-bootstrap-fixpoint.sh target/stage0/typelisp.exe
```

Or fetch from PowerShell and invoke the shell script through `bash`:

```powershell
powershell -ep Bypass -f scripts\fetch-stage0.ps1
bash scripts/check-bootstrap-fixpoint.sh target/stage0/typelisp.exe
```

The current raw stage1 compiler implements source-file `compile`; the wrapper
routes that command and implements source-file `build`, package `build`, `run`,
`fmt`, `doc`, `doc --test`, `repl`, and private `debug host-action` directly
enough for the Linux capability smoke, deterministic assembly gate, selfhost
compile manifest, safety corpus, stdlib documentation gate, stdlib selfhost
frontend verifier, repository doctest gate, TypeLisp source format gate, docs
Pages build path, selfhost native generated-program gate, and the external
selfhost compiler corpus. The safety gate falls back to a legacy seed, or skips
a stage1-bundle seed, until stage1 checked trap helpers are available. The
generated-program gates run through the wrapper only when the Linux host-action
drivers are available; old artifacts or missing-driver paths keep an explicit
seed fallback or skip tied to #1327. The `fmt` command routes through a cached
selfhost `format.tl` driver, or through a prebuilt
`TYPELISP_STAGE1_FORMAT_BIN` in the no-Rust lane, so the repository format gate
does not recompile the formatter on every batched invocation. Package builds
route through a cached selfhost `build.tl` driver, or through a prebuilt
`TYPELISP_STAGE1_BUILD_BIN` in the no-Rust lane, and cover manifest-path and
upward-discovery forms in `scripts/check-stage1-wrapper.sh`; direct selfhost
package-build parity remains covered by `scripts/verify-public-tools.sh`.
Seed-only public-tool exceptions remain: `lint`, non-check `test`, full
REPL/LSP public-tool coverage, and the `scripts/verify-public-tools.sh` surface
gate still need either stage1-safe driver linking or dedicated wrapper routing
before they can move off the seed compiler.

### Staged backend primitives (#1114)

The Linux no-Rust gate now runs capability checks with a freshly bootstrapped
stage1 compiler, so source-only selfhost changes should not need a staging
marker just because the published `stage0-latest` artifact lags `main`.
`requires-stage0-symbol` is now a historical marker name for the narrower
Class-B case: a backend/runtime primitive that the no-Rust compiler path cannot
emit yet, usually because a new Rust helper has not been mirrored in
`selfhost/compiler_backend.tl` or because the Windows no-Rust path is still
driven directly by published stage0.

Mark a test that exercises such a staged symbol so the no-Rust gate skips it
only when the build failure mentions that symbol (the Rust-built `Test` job
still runs it):

- `scripts/verify-stdlib.sh`: add a sixth manifest field
  `requires-stage0-symbol:<name>` to the runnable test row, e.g.
  `stdlib/tests/foo_api.tl|42|-|-|-|requires-stage0-symbol:tl_foo`.
- `scripts/verify-inline-tests.sh`: add a directive comment near the top of the
  inline-test file: `;; requires-stage0-symbol: tl_foo`.
- `scripts/verify-integration.sh`: add an optional seventh manifest field to
  the native integration row, e.g.
  `foo_runtime|tests/integration/foo_runtime.tl|42|-|-|-|requires-stage0-symbol:tl_foo`.
  Use a comma-separated marker when one row may fail on any of several staged
  symbols.

A marked test is skipped **only** when its build fails and `<name>` appears in
the build/typecheck output (the undefined-symbol signal); any other build
failure still fails the gate, and unmarked tests are unaffected. Once the
no-Rust compiler path provides the symbol, the marked test builds and runs
normally (with a "drop the marker" notice from the manifest-based verifiers).

Workflow: introduce the primitive + marked stdlib, inline, or native integration
coverage in one PR only when the selfhost no-Rust path cannot emit the primitive
yet, then drop the `requires-stage0-symbol` marker in the PR that mirrors the
primitive into that path. For Windows-only staging, drop the marker after the
published Windows stage0 path can build the marked row normally.

For new selfhost tests:

- Put structural compiler checks next to the owning module as small helpers or a
  `*-self-test` function.
- Prefer inline `(test ...)` items for new source-local runnable checks when a
  generated test harness is enough.
- Add a `*_smoke.tl` driver when the module should be executable through the
  compiler boundary.
- Add standalone source programs to `selfhost/tests/` when the external compiler
  driver should accept or reject them, then update `scripts/verify-selfhost.sh`.
- Add compile/symbol smoke coverage to `selfhost/compile_manifest.txt` for new
  top-level selfhost modules or smoke drivers, or add an explicit `decision`.
- Add public command, package, docs, LSP, REPL, formatter, or platform cases to
  `scripts/verify-public-tools.sh` or the narrower verification script that
  owns that layer.
- If a temporary Rust test is still needed, update
  `RUST_TEST_COVERAGE.md` in the same PR with the replacement path.

### Native integration tests

`scripts/verify-integration.sh` contains the heavier native checks that build
and run TypeLisp programs outside the Rust harness. Linux uses the explicit
`compile -> as -> ld` path; Windows Git Bash/MSYS/Cygwin uses `typelisp build
--target windows-x86_64` and a small PowerShell runner to preserve native
Windows exit codes. Use this layer for behavior that only shows up after
execution: exit status, stdout/stderr, diagnostic rendering, deterministic file
output, and import-aware driver behavior.

The integration manifests live in `tests/integration/native-linux.manifest` and
`tests/integration/native-windows.manifest`. When a program or smoke driver
needs another imported module, add the dependency to the owning manifest row so
the no-Rust runner exercises the same import graph reviewers see locally. The
same script also owns host-specific backend/compiler-driver fixture checks that
are too low-level for a manifest row.

### Selfhost native generated programs

`scripts/verify-selfhost-native.sh` covers Linux-only cases where a selfhost
TypeLisp driver emits assembly that must then assemble, link, and run outside
the Rust harness. It builds `selfhost/compiler_driver.tl`, verifies generated
file-to-file assembly for multi-file imports, stdlib imports, runtime helpers,
dynamic arrays, traps, and stack-argument call shape, and also runs the printed
assembly from `selfhost/emit.tl` and `selfhost/parse.tl`.

This runner is intentionally separate from the plain integration manifest:
manifest rows cover source programs built by the public compiler, while this
script covers generated-program behavior where the generated `.s` is the test
artifact.

### External compiler corpus

The standalone source corpus under `selfhost/tests/` is for programs accepted or
rejected by `selfhost/compile_smoke.tl`. The runner
`scripts/verify-selfhost.sh` builds the smoke compiler once, compiles each
corpus program, and checks the expected exit code, stdout, stderr, or diagnostic.

Each new corpus file must be listed in the script manifest. See
[`selfhost/tests/README.md`](tests/README.md) for the corpus layout and local
runner commands.

### Stdlib module and fixture gate

`scripts/verify-stdlib.sh` owns the canonical stdlib module manifest and the
`stdlib/tests/` fixture manifest. Its default mode is seed-compatible: it runs
the ordinary runnable fixtures and check-only fixtures through `TYPELISP_BIN`
with `--stdlib-root`, preserving staged-symbol skips for rows that need runtime
primitives not yet present in the published seed.

Borrowed-`str` syntax is checked by an explicit stage1-capable mode:

```sh
TYPELISP_BIN=target/no-rust-stage1-wrapper/typelisp \
  TYPELISP_STDLIB_VERIFY_MODE=borrowed-str \
  scripts/verify-stdlib.sh
```

That mode checks only `stdlib/tests/borrowed_str_gate.tl`, which imports the
borrowed-string migration targets and contains a `(& lifetime str)` parameter
plus an explicit borrow call. The Linux no-Rust gate runs this mode through the
freshly bootstrapped stage1 wrapper so stdlib modules can adopt borrowed
signatures before the published stage0 seed is refreshed. Use
`TYPELISP_STDLIB_VERIFY_MODE=all` locally to run both the default fixture set
and the borrowed-`str` source gate with one compiler.

### Stdlib documentation gate

`scripts/verify-stdlib-docs.sh` discovers every `stdlib/*.tl` module, requires
module and item documentation comments, generates Markdown through
`typelisp doc`, and runs `typelisp doc --test` with `--stdlib-root`. The script
is separate from `cargo test` so the Linux no-Rust gate can run it through the
stage1 wrapper's selfhost doc driver. Repository-wide doctests still use the
public-tool route until the remaining wrapper work in #1544 lands, so
borrowed-syntax stdlib examples should be covered by this stdlib docs gate or
by the borrowed-`str` stdlib source gate above rather than relying only on the
repository doctest sweep.

### Repository doctest gate

`scripts/verify-doc-tests.sh` discovers documented `.tl` files under
`stdlib/`, `selfhost/`, `examples/`, and `tests/` by scanning for public
canonical `;#`/`;:` doc comments (legacy `;;;;`/`;;;` are still accepted) or
TypeLisp fenced examples, then runs
`typelisp doc --test` for each file with `--stdlib-root`. This gate is
intentionally separate from `cargo test` and does not use a hand-maintained file
manifest, so adding documented TypeLisp source with fenced examples
automatically adds doctest coverage. In the Linux no-Rust lane it runs through
the stage1 wrapper's selfhost doc driver (the same driver used by the stdlib
documentation gate) whenever the wrapper host-action drivers are available, and
falls back to the seed compiler otherwise.

### Repository inline-test gate

`scripts/verify-inline-tests.sh` discovers `.tl` files with top-level
`(test ...)` items under `selfhost/`, `stdlib/`, `tests/integration/`,
`tools/`, `tests/inline/`, and `examples/`. For each discovered file it type-checks and
then runs the generated inline-test harness with `--stdlib-root`, reporting the
source path and test-runner output in CI logs. This gate is separate from
doctests, manifest corpora, and smoke drivers so source-owned checks can be
added next to the declarations they exercise.

### Stdlib API site

`selfhost/doc_site.tl` builds a static language-reference and stdlib/API HTML
directory from `README.md`, `SPEC.md`, and the explicit top-level stdlib
manifest owned by the selfhost source. The local command is:

```sh
typelisp run selfhost/doc_site.tl -- target/site
```

The generated directory contains `index.html`, `readme.html`, `spec.html`,
`stdlib.html`, `typelisp-docs.css`, and one deterministic `stdlib-*.html` page
for each manifested top-level stdlib module. `README.md` and `SPEC.md` are
rendered through the constrained selfhost Markdown renderer: supported blocks
become HTML, source-repository Markdown links are rewritten to generated pages
or GitHub source links, and unsupported Markdown syntax is emitted as escaped
literal text. The smoke driver `selfhost/doc_site_smoke.tl` checks the
navigation links, generated page anchors, CSS asset marker, duplicate output
detection, manifest count guard, and HTML escaping behavior without depending
on file-system writes.

To validate the on-disk site end to end (build it, run the smoke driver, and
check that required pages/assets exist and every local link and anchor
resolves), run the non-publishing verifier:

```sh
TYPELISP_BIN=target/debug/typelisp scripts/verify-doc-site.sh
```

It builds into `target/doc-site-verify/`, with native builder logs and objects
in `target/doc-site-verify-work/`, asserts `doc_site_smoke.tl` passes (exit 42),
and fails on a build error, a missing required page, a dead local link, or an
unresolved anchor. Set `DOC_SITE_OUT` to choose a publish-ready output
directory. CI runs it on pull requests and default-branch pushes without
deploying; the GitHub Pages publish workflow (#874) gates on it before uploading
the artifact.

### CI expectations

Pull requests get Linux and Windows no-Rust coverage from
`scripts/verify-no-rust-stage0.sh`. The Linux job first builds a fresh stage1
compiler from published stage0, then smoke-tests the stage1 CLI/host-action
wrapper, deterministic assembly, the selfhost compile manifest, stdlib
documentation, the stdlib selfhost frontend verifier, the safety corpus, the
repository doctest gate, runnable inline tests when a bundled test driver is
present, the TypeLisp source format gate, docs Pages build, selfhost native
generated programs, and the selfhost external compiler corpus through that
wrapper. The safety gate falls back to a legacy seed, or skips a stage1-bundle
seed, until stage1 checked trap helpers are available; the doctest, format, and
generated-program gates fall back only when the wrapper host-action drivers are
unavailable. Public tools, native integration manifests, examples, and stdlib
modules continue to use the seed compiler until their remaining public-tool and
manifest exceptions are ported to the wrapper. The borrowed-`str` stdlib source
routing is the stage1-backed exception for stdlib syntax migration work. The
Windows job
runs the host-supported gates against the published stage0 compiler, verifies
MSVC `link.exe` selfhost build/run support, runs the Windows bootstrap
stage2/stage3 fixpoint, and explicitly skips the Linux-only selfhost/docs
checks.

The remaining Linux and Windows `cargo test`, `cargo fmt`, `cargo clippy`, and
release integration jobs are temporary Rust reference coverage until #795.

For a selfhost compiler change, a typical local check is:

```sh
cargo fmt
cargo test --test tl_compiler_parse_compile
cargo test --test tl_compiler_lower_compile
cargo test --test tl_compiler_backend_compile
TYPELISP_BIN=./target/debug/typelisp ./scripts/verify-selfhost-compile-manifest.sh
TYPELISP_BIN=./target/debug/typelisp ./scripts/check-tl-format.sh
TYPELISP_BIN=./target/debug/typelisp ./scripts/check-tl-lint.sh
TYPELISP_BIN=./target/debug/typelisp ./scripts/verify-public-tools.sh
TYPELISP_BIN=./target/debug/typelisp ./scripts/verify-stdlib-docs.sh
TYPELISP_BIN=./target/debug/typelisp ./scripts/verify-doc-tests.sh
TYPELISP_BIN=./target/debug/typelisp ./scripts/verify-inline-tests.sh
TYPELISP_BIN=./target/debug/typelisp ./scripts/verify-selfhost.sh
scripts/verify-no-rust-stage0.sh
```

`scripts/check-tl-lint.sh` runs `typelisp lint` over tracked TypeLisp source
units and fails CI on any finding.

Run the tests that match the layer you touched. On non-Linux platforms, scripts
that require native `as`/`ld` either no-op by design or should be run through a
Linux environment.

## Checklist for new coverage

- Pick the smallest useful layer: module-local assertion, smoke driver, external
  corpus case, script runner, or temporary Rust bridge test with a recorded
  no-Rust replacement.
- Add or extend a module-local `*-self-test` for compiler internals that can be
  checked structurally.
- Add or update a `*_smoke.tl` wrapper when the self-test should be executable.
- If a temporary Rust compile test is still required, update the matching
  `tests/tl_*_compile.rs` test and the replacement map in the same PR.
- Keep dependency staging in sync for `tests/integration/native-*.manifest` and
  the host fixture sections in `scripts/verify-integration.sh` whenever imports
  change.
- Use `selfhost/tests/` plus `scripts/verify-selfhost.sh` for source programs
  that should be accepted or rejected by `compile_smoke.tl`.
- Use inline `(test ...)` items for source-owned runnable checks; they are
  picked up automatically by `scripts/verify-inline-tests.sh`.
- Keep `selfhost/compile_manifest.txt` in sync with top-level selfhost sources
  and compile/symbol smoke expectations.
- Update `RUST_TEST_COVERAGE.md` whenever adding or changing Rust tests.
- Prefer naming conventions and representative examples in docs and comments;
  avoid maintaining long file lists that will go stale.
- Run the focused tests for the layer touched, plus `cargo fmt`.
