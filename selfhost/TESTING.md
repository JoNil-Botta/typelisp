# Selfhost compiler testing

This guide describes the testing convention for compiler-facing TypeLisp code
under `selfhost/`. The self-hosted compiler is built in layers, so tests
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
imports additional selfhost files, keep the compile manifest in sync (see below).

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

### Selfhost compile manifest

Compile/symbol smoke coverage is driven by
[`compile_manifest.txt`](compile_manifest.txt), checked by
[`../scripts/verify-selfhost-compile-manifest.sh`](../scripts/verify-selfhost-compile-manifest.sh).
The runner compiles each manifest case with an already-built TypeLisp compiler,
rejects generated `# TODO` assembly, applies the case's `main:` label policy,
and checks representative symbol/literal markers in the emitted assembly.
By default those markers are checked in `stage0` mode (the published seed's
symbol coverage). The Linux capability tier also runs the same manifest through
the freshly bootstrapped stage1 compiler with
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

### Coverage policy

New behavior should get TypeLisp-owned coverage: a module-local self-test, a
smoke driver, a corpus fixture, or a shell/script runner that uses an existing
TypeLisp compiler artifact. All implementation and test logic is TypeLisp; the
toolchain has no other-language sources.

### Published stage0 artifact

After each merge to `main`, the `Bootstrap Stage0` workflow publishes Linux and
Windows compiler assets to the `stage0-latest` release and to an immutable
`stage0-*` release. Fetch the compiler with:

```sh
scripts/fetch-stage0.sh
TYPELISP_BIN=./target/stage0/typelisp ./scripts/verify-selfhost.sh
```

Each published asset is a single self-hosted `selfhost/cli.tl` binary
(`typelisp-stage0-linux`, `typelisp-stage0-windows.exe`) that handles every
toolchain command (compile/build/run/check/fmt/lint/test/doc, plus
`debug host-action`) in-process. The `Bootstrap Stage0` workflow is
self-perpetuating: it fetches the previously published stage0 and uses it to
build the next stage0 via [`../scripts/build-stage0.sh`](../scripts/build-stage0.sh)
(`compile selfhost/cli.tl` + native link). There is no Rust seed.

Use `scripts/fetch-stage0.sh <stage0-tag>` to pin an immutable artifact. The
script downloads the host platform asset, verifies the file is non-empty,
checks `SHA256SUMS` when the release provides it, and installs the command under
`target/stage0/`. It uses release asset URLs instead of fetching git tags, so the
mutable `stage0-latest` tag cannot be stale or clobber a local tag.

The complete local verification gate is:

```sh
scripts/verify-no-rust-stage0.sh
```

That script fetches `stage0-latest` when `TYPELISP_BIN` is unset and treats it
as the seed compiler. It installs failing `cargo` and `rustc` shims in `PATH` as
defense-in-depth so no gate can shell out to a language toolchain. On every host
it first builds a fresh `selfhost/cli.tl` binary from the seed and smoke-tests
public `compile`, `build`, `run`, package build, staticlib build, and chooser
execution through that fresh binary. On Linux it then runs the stage1-build path
in `check-bootstrap-fixpoint.sh`, captures the freshly bootstrapped compile-only
stage1 compiler, and routes compile-native capability gates through that
artifact via `compile`/`check` plus the host `as`/`ld` pipeline. The old seed
path remains only as an explicit fallback for old artifacts or missing command
drivers, with the remaining command-tier gaps tracked by #1662. On Windows it
uses the seed compiler for host-supported gates, then runs the native MSVC
`link.exe` build/run smoke and the full stage2/stage3 Windows fixpoint when the
seed has the required staged runtime symbols.

The verify-*/check-* scripts that previously fell back to `cargo build` when
`TYPELISP_BIN` is unset now fetch the published stage0 instead (via
`scripts/lib-stage0.sh`); CI always passes `TYPELISP_BIN` explicitly.

`scripts/check-bootstrap-fixpoint.sh` is host-sensitive. Linux uses the existing
`as` plus `ld` path and compares Linux `stage2.s` with `stage3.s`. Git
Bash/MSYS/Cygwin on Windows emits `windows-x86_64` assembly, assembles each
stage with `clang --target=x86_64-pc-windows-msvc -c`, links `stage1.exe` and
`stage2.exe` with MSVC `link.exe`, runs both generated compilers, and compares
the Windows `stage2.s` and `stage3.s` outputs. Local Windows prerequisites are
Clang, Visual Studio/MSVC `link.exe`, and a Windows SDK; set
`TYPELISP_WINDOWS_CLANG` or `TYPELISP_WINDOWS_LINK` to override discovery.
The stage1 CLI smoke also runs from a scratch directory without a colocated
`stdlib/` to verify embedded stdlib fallback, then checks that
`TYPELISP_STDLIB_ROOT` still overrides embedded contents.

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

The bootstrapped stage1 compiler captured by the no-Rust gate is intentionally
compile-focused. It serves `compile` and `check` directly, which is enough for
the Linux deterministic assembly gate, selfhost compile manifest, safety corpus,
native integration corpus, examples, stdlib module/fixture verifier, and
borrowed-str source gate. Those runnable corpora assemble and link with the host
toolchain after stage1 emits assembly. Public `build`/`run`/package behavior and
the chooser smoke are covered by the separately built fresh `cli.tl` binary on
both Linux and Windows. Larger command-tier gates that require full
`build`/`run`/`doc`/`test` execution from the bootstrapped stage1 stay on an
explicit fallback or skip path until #1662 and the resource-heavy blockers such
as #1437 are closed.

### Staged backend primitives (#1114)

The Linux gate runs capability checks with a freshly bootstrapped
stage1 compiler, so source-only selfhost changes should not need a staging
marker just because the published `stage0-latest` artifact lags `main`.
`requires-stage0-symbol` covers the narrower case of a backend/runtime
primitive that the *published* stage0 (the seed/Windows-driving compiler) cannot
emit yet, even though the in-tree `selfhost/compiler_backend.tl` source already
implements it. The marker lets such a row land before the next stage0 republish
catches up.

Mark a test that exercises such a staged symbol so the gate skips it
only when the build failure mentions that symbol:

- `scripts/verify-stdlib.sh`: add a sixth manifest field
  `requires-stage0-symbol:<name>` to the runnable test row, e.g.
  `stdlib/tests/foo_api.tl|42|-|-|-|requires-stage0-symbol:tl_foo`.
- `scripts/verify-inline-tests.sh`: add a directive comment near the top of the
  inline-test file: `;; requires-stage0-symbol: tl_foo`.
- `scripts/verify-doc-tests.sh`: add the same directive comment near the top of
  a documented `.tl` file whose doctests import a staged primitive.
- `scripts/verify-integration.sh`: add an optional seventh manifest field to
  the native integration row, e.g.
  `foo_runtime|tests/integration/foo_runtime.tl|42|-|-|-|requires-stage0-symbol:tl_foo`.
  Use a comma-separated marker when one row may fail on any of several staged
  symbols.

A marked test is skipped **only** when its build fails and `<name>` appears in
the build/typecheck output (the undefined-symbol signal); any other build
failure still fails the gate, and unmarked tests are unaffected. Once the
published stage0 provides the symbol, the marked test builds and runs
normally (with a "drop the marker" notice from the manifest-based verifiers).

For a stdlib runnable fixture with a narrowed runtime-only blocker, use
`requires-runtime-gap:<host>:#NNNN:<stderr-substring>` as the sixth
`scripts/verify-stdlib.sh` manifest field, where `<host>` is `linux`,
`windows`, or `all`. That marker skips only on the named host when the row
builds, exits with the wrong status, and stderr contains the tracked substring.
If the row starts passing on that host, the verifier reports that the marker
should be removed.

Workflow: introduce the primitive in `selfhost/compiler_backend.tl` plus the
marked stdlib, inline, or native integration coverage in one PR when the
published stage0 cannot emit the primitive yet, then drop the
`requires-stage0-symbol` marker once a stage0 republish carries it. For
Windows-only staging, drop the marker after the published Windows stage0 path can
build the marked row normally.

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

### Native integration tests

`scripts/verify-integration.sh` contains the heavier native checks that build
and run TypeLisp programs as native executables. Linux uses the explicit
`compile -> as -> ld` path; Windows Git Bash/MSYS/Cygwin uses
`compile --target windows-x86_64`, `clang`, `lld-link`, and a small PowerShell
runner to preserve native Windows exit codes. Use this layer for behavior that
only shows up after execution: exit status, stdout/stderr, diagnostic rendering,
deterministic file output, and import-aware driver behavior.

The integration manifests live in `tests/integration/native-linux.manifest` and
`tests/integration/native-windows.manifest`. When a program or smoke driver
needs another imported module, add the dependency to the owning manifest row so
the no-Rust runner exercises the same import graph reviewers see locally. The
same script also owns host-specific backend/compiler-driver fixture checks that
are too low-level for a manifest row.

### Selfhost native generated programs

`scripts/verify-selfhost-native.sh` covers Linux-only cases where a selfhost
TypeLisp driver emits assembly that must then assemble, link, and run as a native
executable. It builds `selfhost/compiler_driver.tl`, verifies generated
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

### Stdlib documentation gate

`scripts/verify-stdlib-docs.sh` discovers every `stdlib/*.tl` module, requires
module and item documentation comments, generates Markdown through
`typelisp doc`, and runs `typelisp doc --test` with `--stdlib-root`. It is a
command-tier gate, so the Linux no-Rust lane runs it through the bootstrapped
stage1 only when the doc command driver is available; otherwise the explicit
fallback/skip path is tied to #1662 and #1437.

### Repository doctest gate

`scripts/verify-doc-tests.sh` discovers documented `.tl` files under
`stdlib/`, `selfhost/`, `examples/`, and `tests/` by scanning for public
canonical `;#`/`;:` doc comments or TypeLisp fenced examples, then runs
`typelisp doc --test` for each file with `--stdlib-root`. This gate does not
use a hand-maintained file manifest, so adding documented TypeLisp source with fenced examples
automatically adds doctest coverage. In no-Rust command-tier lanes it runs
through the compiler selected by `scripts/verify-no-rust-stage0.sh`; runnable
doctest files are required and executed on both Linux and Windows.

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
TYPELISP_BIN=target/stage0/typelisp scripts/verify-doc-site.sh
```

It builds into `target/doc-site-verify/`, with native builder logs and objects
in `target/doc-site-verify-work/`, asserts `doc_site_smoke.tl` passes (exit 42),
and fails on a build error, a missing required page, a dead local link, or an
unresolved anchor. Set `DOC_SITE_OUT` to choose a publish-ready output
directory. CI runs it on pull requests and default-branch pushes without
deploying; the GitHub Pages publish workflow (#874) gates on it before uploading
the artifact.

### CI expectations

Pull requests get Linux and Windows coverage from the single self-hosted
verification gate `scripts/verify-no-rust-stage0.sh` (wired in
[`../.github/workflows/ci.yml`](../.github/workflows/ci.yml)). Both jobs first
build a fresh `selfhost/cli.tl` binary from the published stage0 compiler and
smoke-test public `compile`, `build`, `run`, package build, staticlib build, and
the work-queue chooser through `typelisp run`. The Linux job then bootstraps a
compile-only stage1 compiler and runs deterministic assembly, the selfhost
compile manifest, borrowed-str source checks, the safety corpus, native
integration manifests, standalone examples, and stdlib modules/fixtures through
that bootstrapped artifact. Command-tier gates such as public-tool host-action
coverage, stdlib documentation, doctests, inline tests, docs Pages build,
selfhost native generated programs, and the external selfhost corpus use their
explicit seed/fresh-cli fallback or skip paths until #1662 and related resource
blockers are closed. The Windows job runs host-supported gates against the
published stage0 compiler, verifies the fresh CLI build/run smoke, runs the
Windows bootstrap stage2/stage3 fixpoint when staged runtime symbols are present,
and explicitly skips the Linux-only selfhost/docs checks.

For a selfhost compiler change, a typical local check (after
`scripts/fetch-stage0.sh`, with `tl=target/stage0/typelisp[.exe]`) is:

```sh
$tl fmt --check selfhost/<changed>.tl
TYPELISP_BIN=$tl ./scripts/verify-selfhost-compile-manifest.sh
TYPELISP_BIN=$tl ./scripts/check-tl-format.sh
TYPELISP_BIN=$tl ./scripts/check-tl-lint.sh
TYPELISP_BIN=$tl ./scripts/verify-public-tools.sh
TYPELISP_BIN=$tl ./scripts/verify-stdlib-docs.sh
TYPELISP_BIN=$tl ./scripts/verify-doc-tests.sh
TYPELISP_BIN=$tl ./scripts/verify-inline-tests.sh
TYPELISP_BIN=$tl ./scripts/verify-selfhost.sh
scripts/verify-no-rust-stage0.sh
```

`scripts/check-tl-lint.sh` runs `typelisp lint <file.tl> --check` over tracked
TypeLisp source units and fails CI on any finding. Plain `typelisp lint
<file.tl>` remains warn-only for reviewable cleanup slices.

Run the tests that match the layer you touched. On non-Linux platforms, scripts
that require native `as`/`ld` either no-op by design or should be run through a
Linux environment.

## Checklist for new coverage

- Pick the smallest useful layer: module-local assertion, smoke driver, external
  corpus case, or script runner.
- Add or extend a module-local `*-self-test` for compiler internals that can be
  checked structurally.
- Add or update a `*_smoke.tl` wrapper when the self-test should be executable.
- Keep dependency staging in sync for `tests/integration/native-*.manifest` and
  the host fixture sections in `scripts/verify-integration.sh` whenever imports
  change.
- Use `selfhost/tests/` plus `scripts/verify-selfhost.sh` for source programs
  that should be accepted or rejected by `compile_smoke.tl`.
- Use inline `(test ...)` items for source-owned runnable checks; they are
  picked up automatically by `scripts/verify-inline-tests.sh`.
- Keep `selfhost/compile_manifest.txt` in sync with top-level selfhost sources
  and compile/symbol smoke expectations.
- Prefer naming conventions and representative examples in docs and comments;
  avoid maintaining long file lists that will go stale.
- Run the focused tests for the layer touched, plus `typelisp fmt --check`.
