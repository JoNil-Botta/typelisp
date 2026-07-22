# Selfhost compiler testing

This guide describes the testing convention for compiler-facing TypeLisp code
under `src/`. The self-hosted compiler is built in layers, so tests
are also layered: keep each case at the lowest layer that proves the behavior,
then add runnable or end-to-end coverage only when that extra boundary matters.

The broader work is tracked by the parity umbrella
[#641](https://github.com/JoNil-Botta/typelisp/issues/641), the selfhost CI
suite gate [#520](https://github.com/JoNil-Botta/typelisp/issues/520), and the
bootstrap/fixpoint gate [#47](https://github.com/JoNil-Botta/typelisp/issues/47).
The gate/tool classification and canonical script entry points are documented
in [`../scripts/README.md`](../scripts/README.md).

## Intern-ID provenance

Name ids in `AstDecl`, `AstExpr`, patterns, parameters, fields, and nominal
`AstType` nodes are owned by one `InternCompatState` table. Parsed token slices,
compiler-generated module/hygiene/builtin names, and String-taking compatibility
constructors all enter that same active table. Empty spellings are valid
interned names when synthesis needs them. AST fallback payloads, negative
sentinels, and structural composite keys are not intern ids; use the owning
subsystem's renderer rather than `intern-str` for those values. Lifetime/region
names, diagnostics, import metadata, and compatibility records may legitimately
remain `String` values.

Within an installed state, insertion order makes ids deterministic. Installing
another driver state changes the owner even when its generation counter and
numeric ids happen to match. A full reset invalidates all retained ids.
Reset-to-mark preserves the numeric prefix below the mark but still advances the
generation, so long-lived consumers must recapture provenance before reuse.
State-owned reset/capture/install operations affect only that driver job.

`intern-str` is the short-lived, same-state compatibility path. Tests and code
that retain an id across reset or install boundaries must capture
`InternIdProvenance` and use `intern-id-render`; wrong-owner, stale-generation,
and out-of-range values are rejected explicitly. Do not cache String data
pointer/length pairs as name identity across scratch/region reset: address
equality is only a fast path while both live operands are in scope. Interning
must own/canonicalize any spelling that survives its source arena.

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
- `compiler-live-self-test`,
  `compiler-regalloc-self-test`, and `compiler-backend-self-test`
- `compiler-optimize-self-test` plus the pass-specific optimizer self-tests

Prefer small hand-built fixtures and deterministic structural assertions over
large golden strings. A runnable self-test returns `42` on success. Failures
should be specific enough to identify the broken layer; using `panic` with a
short module-prefixed message is normal when a boolean helper fails. Aggregator
self-tests must name each failed check instead of mapping predicates or child
self-tests to magic exit codes. A leaf self-test may temporarily retain a
numeric status when changing it would obscure a large fixture, but its caller
must print the leaf's name and returned/expected status before failing.

### Smoke drivers

A `*_smoke.tl` file is the runnable wrapper for one or more module-local
self-tests. It should contain little logic: import the module, call the
self-test, and return `42` only when the checks pass. Examples include
`compiler_parse_smoke.tl`, `compiler_lower_smoke.tl`,
`compiler_optimize_smoke.tl`, and `compiler_backend_smoke.tl`.

Smoke drivers and their fixtures live under `src/tests/` (a reserved package
test directory, excluded from the source/closure scan). They are built and run
as exit-42 integration cases by `tests/integration/native-*.manifest`. Place a
new smoke beside the others in `src/tests/`; import source modules by their
direct relative path from that directory, such as `../compiler_parse_core.tl`,
so the driver also runs from the repository root with `typelisp run`.

Use a smoke driver when the module is main-less or when CI needs to compile and
run the module through the TypeLisp executable boundary.

Heavy smoke wrappers may be listed in a native manifest suite's eighth
`suite-members:` field. A suite compiles shared compiler modules once, then
launches its own binary with one named child argument per member so mutable
compiler globals retain the fresh-process behavior of standalone drivers. Keep
the original driver as a thin runnable wrapper and place shared test bodies in
a main-less `src/*_tests.tl` helper. Manifest validation requires every suite
member to remain an executable `src/tests/*_smoke.tl`, be named by the suite
source, and not also appear as a standalone manifest source.

## Intern ID provenance

Parser tokens enter the source interner once through `intern-source-slice` and
AST name fields retain that ID. Compiler-created names enter through an explicit
`intern-generated-*` API; canonical and opaque generated names have different
identity rules. Builtin/fixed IDs, macro hygiene names, dotted names, and
module-qualified names are created or mapped by their owning ID API rather than
by interning a rendered String in a later compiler phase.

An intern ID belongs to one installed `InternCompatState` table and generation.
`intern-reset!` invalidates every previous ID in that state;
`intern-reset-to!` preserves only source IDs below the mark and invalidates all
generated IDs. A driver must install the ID's owner before lookup or rendering.
The same numeric ID may mean different text in two driver states.

Negative missing/sentinel values and packed composite symbol keys are not intern
IDs. They may key registries and environments as `i64`, but must not be passed to
`intern-str`. String-taking AST constructors remain compatibility boundaries for
synthetic callers until those callers have an explicit owner-state ID; parser-only
and ID-first constructors should not recover an ID from String storage.

`compiler_intern.tl` self-tests own reset cases,
`compiler_intern_state_isolation.tl` owns explicit worker-state isolation, and
`compiler_backend_smoke.tl` covers equal numeric IDs with different spellings.
`compiler_ast_types_smoke.tl` owns synthetic AST construction, empty-name
compatibility, and pool reset cases. `compiler_parse_smoke.tl` owns parsed-token
identity.

### src/ reachability

The package follows the standard layout: `typelisp build` resolves the default
`src/main.tl` entry (no explicit `entry` in `typelisp.pkg`), and every top-level
`src/*.tl` is reachable from `main.tl` except deliberate test/staging modules:
`tlci_core.tl`, `tlci_pages.tl`, and `tlci_loader.tl` (staged tlci feature
modules with dedicated smokes, #2651/#2671/#2657), plus
`compiler_backend_tests.tl`, `compiler_driver_smoke_tests.tl`, and
`compiler_lower_package_tests.tl` (main-less native smoke helpers). These carry
`decision` rows in the compile manifest.

### Inline tests

Top-level `(test name body...)` items are source-owned executable checks. Normal
`check`, `compile`, `build`, and `run` ignore them. `typelisp test <file.tl>`
loads the import graph, turns tests owned by the requested source into private
unit-returning functions, skips any production `main`, generates a test-owned
`main`, and runs the resulting executable. Imported files provide runtime
declarations but do not contribute their own inline tests to that harness. With
no file, `typelisp test` discovers the nearest package and runs package sources
that contain top-level inline tests, plus package-local `tests/**/*.tl`
integration test files; stdlib and dependency imports provide runtime
declarations only. Integration test files run as normal programs: a `main` exit
status of `0` passes, while any non-zero status fails the package test command
with exit `1`. `typelisp test --check` type-checks generated inline harnesses
and integration test files without assembling or linking. Package integration
discovery skips the reserved
`tests/diagnostics/**`, `tests/format_golden/**`, `tests/golden/**`,
`tests/inline/**`, `tests/no-libc/**`, `tests/public-tools/**`,
`tests/safety/**`, and `tests/spmd/**` fixture corpora. When
`tests/integration/native-*.manifest` exists, package discovery also leaves
`tests/integration/**` to the explicit integration runner. Dedicated
verification scripts own those files.

Package-wide source discovery for commands such as `check`, `fmt`, `lint`, and
`doc` treats directories named `tests` as reserved package test/fixture roots
instead of ordinary package sources. The `typelisp test` command owns
package-local `tests/` discovery through the integration-test path above.

Use inline tests for behavior that naturally belongs next to the declarations
under test. Import `stdlib/test.tl` for assertions such as `assert-i64-eq`.
Keep smoke drivers for existing compiler-module self-tests until those modules
are intentionally migrated.

[`../scripts/verify-inline-tests.sh`](../scripts/verify-inline-tests.sh)
auto-discovers top-level inline tests under `src/`, `stdlib/`, `tools/`,
`tests/integration/`, `tests/inline/`, and `examples/`. It runs
one batched `typelisp test --check --batch <listfile>` process first, then
per-file `typelisp test` executions, so malformed, untyped, unbuildable, and
failing inline tests all fail CI without a hand-maintained manifest update.

### Selfhost compile manifest

Compile/symbol smoke coverage is driven by
[`compile_manifest.txt`](compile_manifest.txt), checked by
[`../scripts/verify-selfhost-compile-manifest.sh`](../scripts/verify-selfhost-compile-manifest.sh).
The runner compiles each manifest case with an already-built TypeLisp compiler,
rejects generated `# TODO` assembly, applies the case's `main:` label policy,
and checks representative symbol/literal markers in the emitted assembly.
`_tl_foo` and `call _tl_foo` markers are logical symbol
markers, so both expectation modes accept direct labels such as `_tl_foo` and
emitted module/path-qualified labels such as `_tl_calc_foo` without changing the
manifest list. CI runs the manifest on the bootstrapped stage2 compiler with
`TYPELISP_COMPILE_MANIFEST_EXPECTATION_MODE=stage1` on both hosts; in that mode
symbol markers also accept compact selfhost symbol metadata. The default
`stage0` mode remains for standalone runs against the published seed.
Use `requires-stage0-mode|<reason>` only for a case that must remain seed-only
for a named blocker such as the current #1437 stage1->stage2 resource limit.

Every top-level `src/*.tl` file must appear as a manifest `case` or a
`decision` line. This makes new modules and smoke drivers fail CI until they
have an explicit compile-coverage decision. Staged cases cover integration
drivers whose imports need temporary sibling names, such as the text buffer and
symbol-table drivers.

### Cross-Target Codegen Parity

Use [`../scripts/check-codegen-target-parity.sh`](../scripts/check-codegen-target-parity.sh)
to catch Linux/Windows drift before backend assembly. The script compiles a
small non-target-cfg corpus with `compile --emit-ir` for `linux-x86_64` and
`windows-x86_64` at opt levels 0, 1, and 2, then diffs the deterministic IR
summaries. It also fails if target-specific tokens appear in
`src/compiler_optimize.tl`, keeping the optimizer target-independent. A
separate target-cfg probe confirms that `compile --emit-ir --target` is actually
honoring the requested target. The same gate runs
[`../scripts/check-codegen-target-dispatch.sh`](../scripts/check-codegen-target-dispatch.sh),
which checks the lowerer/backend target-dispatch inventory in
[`../scripts/codegen-target-dispatch-allowlist.tsv`](../scripts/codegen-target-dispatch-allowlist.tsv).
New Linux/Windows dispatch sites in `src/compiler_lower.tl` or
`src/compiler_backend.tl` must be classified there as `abi`, `runtime`,
`target-cfg`, `backend-mode`, `entry`, `object-format`, `test-only`, or
`transitional`; otherwise the parity gate fails.

```sh
TYPELISP_BIN=target/stage0/typelisp scripts/check-codegen-target-parity.sh
```

### IR Dumps, Pass Tracing, and Verification

Compiler-development builds expose three opt-in `typelisp compile` diagnostics:

- `--dump-ir` writes the deterministic final textual IR to `-o` (or the
  input's `.ir` path).
- `--dump-ir after-<pass>` writes every function snapshot observed immediately
  after the named optimizer pass. Pass names use the trace spelling, including
  `fold`, `ssa`, `gvn`, `licm`, `global_gvn`, and `dce`.
- `--trace-passes` writes one
  `optimizer-pass|<function>|<pass>|blocks=<n>|instructions=<n>` record per
  observed boundary to stderr.
- `--verify-ir` runs structural final-IR verification and the full SSA
  dominance/use verifier for SSA-shaped functions before any output file is
  written. Failures name the function and, for operand failures, the block and
  instruction index.

The checked-in pass golden is
[`../tests/golden/optimizer_fold.after-fold.ir`](../tests/golden/optimizer_fold.after-fold.ir).
Run the focused cross-platform gate with a current compiler:

```sh
TYPELISP_BIN=target/stage0/typelisp scripts/verify-ir-observability.sh
```

When an intentional IR change updates the golden, generate it with
`compile tests/golden/optimizer_fold.tl --dump-ir after-fold --verify-ir
--opt-level 1`, inspect the diff, and run the focused gate. An unknown pass is
an error and does not create the requested output.

Use [`../scripts/check-backend-target-asm-parity.sh`](../scripts/check-backend-target-asm-parity.sh)
for the next layer down: normalized Linux/Windows assembly parity for selected
user helper bodies. The script compiles a conservative corpus for both targets
at opt levels 0, 1, and 2, strips target-owned wrappers and assembler metadata,
normalizes compiler-generated local labels, and diffs the resulting helper
bodies. It also has a `--self-test` mutation mode that proves the diff gate
fails when a normalized body changes.

```sh
TYPELISP_BIN=target/stage0/typelisp scripts/check-backend-target-asm-parity.sh
TYPELISP_BIN=target/stage0/typelisp scripts/check-backend-target-asm-parity.sh --self-test
```

The corpus intentionally avoids C ABI fixtures, source-level target cfgs, and
runtime-helper-heavy programs. The assembly parity corpus is even narrower: it
compares helper bodies only after function prologues, and deliberately leaves
direct C ABI call setup, indirect-call register differences, shadow space,
sret, stack probing, entry symbols, and runtime shims to the backend smoke and
native integration layers. The normalizer has a narrow target-ABI model for the
former opt2 scalar-parameter-home mismatches: selected incoming scalar argument
registers, plus stack homes forced by target scratch registers, normalize to
`%ABI<n>` pseudo operands for the affected corpus helpers only. Any normalized
helper-body difference is treated as a regression unless the script is
deliberately updated with a tightly scoped, stale-entry-checked expected
mismatch.

### One-shot compile startup profiling

`compile-startup-profile` is a build cfg for attributing one fresh `typelisp
compile` process from the earliest source global through the start of user-entry
loading. It records raw monotonic ticks in memory and prints them only after the
compile finishes, keeping marker formatting and stderr I/O outside the measured
preamble. The required cross-platform verifier builds an instrumented compiler,
checks marker presence/order, and requires its generated assembly to match the
normal compiler:

```sh
TYPELISP_BIN=target/stage0/typelisp scripts/verify-compile-startup-profile.sh
```

For native Windows distributions, use
[`../scripts/measure-compile-startup.ps1`](../scripts/measure-compile-startup.ps1)
with a compiler built using `--cfg compile-startup-profile` and, for embedded
surface-hydration attribution, `--cfg embedded-stdlib-tlci`. A normal compiler
from the same source revision can be supplied as `-BaselineCompiler`; the
harness alternates process order and writes raw `markers.tsv`, per-run
`samples.tsv`, percentile `summary.tsv`, and environment/compiler hashes in
`metadata.tsv`:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\measure-compile-startup.ps1 `
  -Compiler target\compile-startup\typelisp-profile.exe `
  -BaselineCompiler target\compile-startup\typelisp-control.exe `
  -Source target\compile-startup\empty.tl
```

These wall-clock distributions are diagnostic local measurements rather than
committed performance baselines. Keep the source, compiler revisions, cfgs,
warmups, iteration count, and Defender state with any reported comparison.

### Assembly size reports

Use [`../scripts/analyze-selfhost-build-asm-size.sh`](../scripts/analyze-selfhost-build-asm-size.sh)
for local code-size comparisons of the selfhost compiler. It compiles
`src/main.tl` with `TYPELISP_BIN` when set, otherwise with the published
stage0 selected by `scripts/lib-stage0.sh`, then prints total assembly
bytes/lines, section totals, top `.text` symbols, module/file buckets inferred
from TypeLisp symbol names, and generated clone-helper totals:

```sh
TYPELISP_BIN=target/stage0/typelisp scripts/analyze-selfhost-build-asm-size.sh
```

Use `--top N` to change the table size, `TYPELISP_ASM_SIZE_OUT` to choose the
artifact directory, and `--asm target/path/build.s` to analyze an existing
assembly file without recompiling. The report is intentionally a local
measurement tool, not a CI size gate.

Use [`../scripts/analyze-stage0-size.sh`](../scripts/analyze-stage0-size.sh)
for linked stage0 binary size comparisons. It reports total file bytes, section
raw sizes from `llvm-readobj`, `readelf`, or `objdump`, plus bounded static,
compressed-token, and expanded exact-source embedded stdlib payload bytes:

```sh
scripts/fetch-stage0.sh
scripts/analyze-stage0-size.sh target/stage0/typelisp
scripts/build-stage0.sh target/stage0/typelisp target/stage0-branch/typelisp
scripts/analyze-stage0-size.sh target/stage0-branch/typelisp
```

On Windows, run the shell commands from Git Bash after fetching the Windows
seed (`target/stage0/typelisp.exe`) and use a `.exe` output path. The stage0
publication smoke also prints this report when a section reader is available,
but it remains a measurement report rather than a size budget gate.

`src/compiler_embedded_stdlib_payload.tl` is the canonical explicit build-input
list. Editing a listed stdlib source changes the next compiler build directly;
there is no generated source to refresh. Run
`scripts/verify-embedded-stdlib-payload.sh` to check declaration completeness,
deterministic output, one-byte source mutation propagation, and byte-for-byte
decoding with a branch-built compiler.

Completed regalloc census harnesses for move traffic, call spans, and emergency
scavenging are preserved under
[`../scripts/attic/`](../scripts/attic/README.md). They are historical
reproduction tools, not current CI gates.

`scripts/measure-instruction-counts.sh` is the Linux-only dynamic instruction
counter for local deterministic performance measurements. It builds TypeLisp
benchmark binaries and their paired `clang -O2` C baselines, runs them under
`valgrind --tool=cachegrind`, then runs a compiler self-compile command under
cachegrind and records the `Ir` event:

```sh
TYPELISP_BIN=target/stage0/typelisp scripts/measure-instruction-counts.sh --runs 3
TYPELISP_BIN=target/stage0/typelisp scripts/measure-instruction-counts.sh --filter arith_loop --benchmarks-only
TYPELISP_BIN=target/stage0/typelisp scripts/measure-instruction-counts.sh --self-compile-only --opt-level 2
```

The script writes `runs.tsv` and `summary.tsv` under
`target/instruction-counts/` by default and fails if a case's `Ir` count differs
across repeated runs. Benchmark summary names are `benchmark/typelisp/<name>`
and `benchmark/c/<name>`, with `self_compile/compile_cli_optN` for compiler
self-compile rows. It intentionally measures full-process instruction counts;
the benchmark loops and self-compile workload dominate startup overhead. The
default output root is repo-relative so the measured self-compile `-o` argument
is stable across machines; use a repo-relative `--output` when collecting counts
intended for baseline comparison.

AVX-512 dynamic instruction counts use the separate hardware PMU harness, not
cachegrind. On a Linux/WSL AVX-512F+BW+DQ host with PMU permission:

```sh
TYPELISP_BIN=target/stage0/typelisp \
  scripts/measure-spmd-avx512-instructions.sh --focused --cpu 4
TYPELISP_BIN=target/stage0/typelisp \
  scripts/measure-spmd-avx512-instructions.sh \
  --runs 11 --check-baseline --cpu 4
scripts/measure-spmd-avx512-instructions.sh --self-test
```

The pure-TypeLisp launcher under `tools/spmd-avx512-perf/` owns synchronized
`perf_event_open`/`execve` counting and signal decoding. Baselines are enforced
within 1000 ppm only when the complete host/tool fingerprint matches; other
hosts are report-only. Keep this full hardware measurement out of required CI
and retain static opcode counts only as structural diagnostics.

For SPMD mode-specific performance, use the separate opt-in
`scripts/measure-spmd-mode-instruction-counts.sh`. It records scalar and AVX2
TypeLisp/clang pairs under unambiguous benchmark+mode+implementation keys,
checks exit parity and the unsupported-mode diagnostic table, and emits ratios
and geomeans without adding the heavy matrix to the normal SPMD correctness
gate:

```sh
TYPELISP_BIN=target/stage0/typelisp \
  scripts/measure-spmd-mode-instruction-counts.sh --runs 1 --check-baseline
scripts/measure-spmd-mode-instruction-counts.sh --self-test
```

Do not add AVX-512 cachegrind rows; use the methodology tracked by #4933.

`scripts/measure-typecheck-prefix-cache.sh` reports the opt-in typecheck prefix
snapshot cache counters for the batch workloads the cache is meant to help:
repeated stdlib imports, one selfhost compile-manifest chunk, and doctests.

```sh
TYPELISP_BIN=target/stage0/typelisp scripts/measure-typecheck-prefix-cache.sh
```

Each line includes elapsed time plus `hits`, `misses`, `stores`, `lookups`, and
integer `hit-rate-per-mille` from the compiler's `--prefix-cache-stats` report.
The repeated compile-batch and doctest workloads also fail when they do not
produce the expected cache hits.

`scripts/measure-lsp-check-latency.sh` is the local interactive LSP latency
harness for repeated `tl/check` requests. It starts one `typelisp lsp` process,
opens generated roughly 500-line and 6000-line documents with a shared stdlib
import, checks invalid syntax, repeats the unchanged check, replaces the text
with valid source, and checks again:

```sh
TYPELISP_BIN=target/stage0/typelisp scripts/measure-lsp-check-latency.sh
```

The harness needs Python 3 from the host only to drive framed stdio JSON-RPC;
it uses no third-party modules. It writes generated sources and captured LSP
stderr under `target/lsp-check-latency/` by default. Each line reports the
request/response elapsed time for `invalid_check`, `unchanged_check`, and
`edited_check`. The unchanged request demonstrates the per-document result
cache; the final stderr-derived `typecheck-prefix-cache|lsp|...` line reports
the compiler's existing shared-import prefix-cache evidence. The printed
targets are informational local comparison points: under 500 ms for the
roughly 500-line edited check, and under 3 s for the roughly 6000-line edited
check. They deliberately do not fail on wall-clock noise. Use
`TYPELISP_LSP_CHECK_SMALL_LINES`, `TYPELISP_LSP_CHECK_LARGE_LINES`, or
`TYPELISP_LSP_CHECK_WORKDIR` to adjust a local run.

`compile --profile-allocations` emits opt-in arena ownership rows for any input
program. Rows report the phase, owner, arena root, bump-position bytes,
committed bytes, reserved bytes, and segment count. Arena roots make overlapping `active` and
named-owner rows explicit so consumers can de-duplicate them. Without the flag,
the compiler emits no rows and keeps the allocator fast path unchanged.
`bump_bytes` includes the retained high-water position of rewound overflow
segments; use `committed_bytes` when reconciling the rows with OS commitment.
In the `typecheck.macro.peak` snapshot, `macro-enclosing`, `macro-scratch`,
`macro-symbols-current`, `macro-symbols-retired`, `macro-symbols-reclaiming`,
`macro-hygiene-cache`, the `typecheck-*` scratch/cache owners, `source-pools`,
`intern-persistent`, and the process-lifetime `compiler-entry` arena identify
the independently owned arenas that are simultaneously live. Repeated
snapshots capture transient symbol-generation overlap without treating retired
roots as concurrent indefinitely.

On Windows, correlate those rows with the compiler process's working set and
private bytes using:

```powershell
scripts/measure-compile-memory.ps1 `
  -Compiler target/stage0/typelisp.exe `
  -Source src/main.tl `
  -OptLevel 1
```

The helper samples the child every 5 ms by default and writes raw owner samples
plus per-phase, de-duplicated committed totals under
`target/compile-memory/windows/`. This distinguishes arena commitment from
unattributed process memory such as stacks, code, and other mappings.

`lsp-frame-run-transcript` is the TypeLisp-only in-process framing adapter for
tests that need exact stdin bytes plus exact captured stdout, stderr, and exit
status. It runs the production frame parser and request handlers in a
destroyable session arena, keeps transport buffers in a separate destroyable
arena so nested tool scratch scopes cannot own captured output, copies the
result to the caller arena, and performs the fresh-session reset before either
arena is destroyed. `src/tests/lsp_frame_smoke.tl` covers EOF/error framing,
ordered messages, message-owned JSON-RPC ids, and document/compiler cache A/B
isolation. Public transcript-corpus discovery and process-count measurement
remain owned by the public-tool verifier rather than this substrate.

`tests/public-tools/run-corpus.sh lsp fresh` retains the original
one-process-per-fixture LSP oracle. `lsp batch` materializes a versioned,
tab-separated manifest whose rows name one case ID, exact raw/framed input,
and separate stdout, stderr, and status files, then runs every logical session
serially through one `typelisp lsp --transcript-batch` process. The TypeLisp
runner validates the complete manifest before executing it, resets state on
both sides of every session, and destroys the session and transport arenas.
Linux defaults to `lsp differential`: all fresh processes plus one batch
process, followed by normalized per-case byte/status comparison before the
existing fixture specs. Windows defaults to `lsp batch`. Use
`scripts/verify-lsp-transcript-batch.sh` for the fast manifest/parser mutation
coverage, including raw malformed-frame input and incomplete result sets.

The completed #3803 unused-import experiment is preserved as
`scripts/attic/measure-unused-import-cost.sh`; see the attic README for its
historical ownership.

`scripts/measure-result-import-cost.sh` is the paired #3903/#3215 diagnostic
harness for generated `(result.result T E)` imports in hot selfhost modules. It copies
`src/*.tl` into scratch trees under `target/` and injects one unused generated
result import into each variant source (`format_tokens.tl`, `lex.tl`, or
`compiler_ctfe.tl`) without editing tracked sources. Linux/cachegrind mode
reports a baseline plus one `self_compile/compile_cli_opt1` instruction-count
delta for each variant; `--profile` also emits phase deltas and generated
macro/import counter deltas. The full cost measurement is opt-in;
`scripts/verify-result-import-harness.sh` invokes its `--prepare-only` path to
gate source-preserving fixture injection.

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
TYPELISP_BIN=./target/stage0/typelisp ./scripts/verify-selfhost-compile-manifest.sh
```

Each published asset is a single self-hosted `src/main.tl` binary
(`typelisp-stage0-linux`, `typelisp-stage0-windows.exe`) that handles every
toolchain command (compile/build/run/check/fmt/lint/test/doc/repl/lsp/new/init)
in-process. The `Bootstrap Stage0` workflow is
self-perpetuating: it fetches the previously published stage0 and uses it to
build the next stage0 via [`../scripts/build-stage0.sh`](../scripts/build-stage0.sh)
(`compile src/main.tl` + native link).

The checkout root also has a `typelisp.pkg` whose binary entry is
`src/main.tl`, so `typelisp build` from the repository root builds the
selfhost CLI package into `target/release/`. The CI smoke keeps a
root package-build check in `scripts/verify-selfhost-cli-build-run.sh`; the
published stage0 workflow intentionally keeps using the direct
`compile src/main.tl` path plus native linking so a seed compiler can build
its successor without depending on its own `build` command.

### Single command surface

The published toolchain is the single `src/main.tl` binary, and every command
(`build`, `run`, `check`, `fmt`, `lint`, `test`, `doc`, `compile`, `clean`,
`repl`, `lsp`, `new`, `init`) is reached only through its dispatcher. There are no
separate per-command driver binaries: each command's logic lives in a main-free
`*_cli_core.tl` module compiled as part of `cli.tl`, and the `selfhost_main`
compile-manifest case asserts every command's dispatch entry, internal symbols,
and diagnostic strings. Gates that need a command binary build `src/main.tl`
and invoke the subcommand directly (e.g. `cli build --direct …`,
`cli check <file>`, `cli fmt --check …`, `cli doc --html …`).

### CLI gate behavior inventory

[`../scripts/cli-gate-coverage.tsv`](../scripts/cli-gate-coverage.tsv) defines
the version-1 machine-readable schema used to inventory compiler invocations in
the three large shell CLI gates. Each owning script is registered with a
`# source<TAB>path` metadata line, and every executing or expanded case has one
inventory row.

The 19 TSV fields are:

1. `schema`, fixed to `1`;
2. stable `case_id` and `gate` names;
3. repository-relative `source` and invocation `kind` (`wrapper`, `direct`, or
   `delegated`);
4. `host`, `compiler`, and normalized `argv` identity;
5. `fixture`, `stdin`, `cwd`, `process`, and `environment` identity;
6. `expected_status`, `stdout`, `stderr`, and filesystem/other `effects`;
7. `canonical_owner` and `duplicate_reason`.

Every field is required. Use `-` for an explicit absence, not an empty field.
Values are compared byte-for-byte after validation: ordering inside composite
fields (argv, environment, assertion lists) is part of the checked schema and
must be deterministic. Literal tab, LF, CR, and percent bytes are written as
`%09`, `%0A`, `%0D`, and `%25`; percent escapes are uppercase, and no other
escape syntax or percent sequence is accepted. Paths are repository-relative
and may not contain `..` components. These rules deliberately avoid inferred
equivalence: stdin bytes, cwd, heartbeat environment, process boundaries, and
each output/effect assertion remain distinct duplicate-key fields.

An inventory row binds to an executing source site through a comment placed
immediately before the wrapper, direct compiler command, or delegated corpus
command:

```sh
# cli-gate-case public-help wrapper run_cmd
run_cmd public-help "$COMPILER" --help
```

The final annotation word is the exact first shell token of the next nonblank,
noncomment line. The checker only proves that narrow binding; it does not parse
arbitrary shell semantics. The annotation kind and source path must match the
inventory row.

Loops and matrices use an explicit Cartesian expansion. Axis and value order is
deterministic, every axis must appear in the ID pattern, and the expanded IDs
each require their own inventory row:

```sh
# cli-gate-expand compile-{host}-{mode} wrapper run_cmd host=linux,windows mode=scalar,avx2
run_cmd "$label" "$COMPILER" compile "$source" --backend-mode "$mode"
```

Run the fast static checker and its fixture self-tests with:

```sh
scripts/check-cli-gate-coverage.sh
scripts/check-cli-gate-coverage.sh --self-test
```

The checker fails closed on malformed rows/expansions, missing or stale
row-to-annotation links, duplicate IDs or annotations, and unknown canonical
owners. The duplicate identity includes every semantic field from `kind`
through `effects`. Exact repeated identities are accepted only when every row
names the same owner from that duplicate group and supplies a non-`-` checked
reason. Successful output contains sorted counts per gate and source site,
one count for every expanded case, and a sorted duplicate report.

The inventory begins with a versioned authoritative count block. A directive
has the form `# count<TAB>scope<TAB>key<TAB>metric<TAB>value`. The checker
recomputes the complete set of total, gate, host, effective-platform,
invocation-kind, process, and duplicate counts and compares it byte-for-byte
with that block. Missing categories, unexpected categories, and stale values
all fail. Effective-platform counts include `host=all` rows. Delegated fixture
sets use:

```text
# child-corpus<TAB>case_id<TAB>host<TAB>directory<TAB>include-glob<TAB>exclude-glob-or--<TAB>count
```

Those counts are rediscovered from regular files in the named directory. This
keeps the LSP and REPL aggregate invocations honest when fixtures are added or
removed without adding more parent shell invocations.

The authoritative inventory at schema version 1 is:

| Gate | Owning source | CI host | Rows | Source sites | Expanded cases |
| --- | --- | --- | ---: | ---: | ---: |
| `public-tools` | `scripts/verify-public-tools.sh` | Linux and Windows | 291 | 182 | 125 |
| `selfhost-cli` | `scripts/verify-selfhost-cli-build-run.sh` | Linux and Windows | 77 | 76 | 16 |
| `stage1-wrapper` | `scripts/check-stage1-wrapper.sh` | Linux | 101 | 85 | 18 |
| Total | three registered sources | mixed | 469 | 343 | 159 |

There are 348 host-neutral rows, 118 Linux-only rows, and 3 Windows-only rows,
so the effective platform totals are 466 on Linux and 351 on Windows. The
invocation split is 410 wrapper, 51 direct, and 8 delegated rows. Every distinct
`process` value and its count is also checked in the count block rather than
being maintained as a second prose table.

Delegated fixture ownership is 63 LSP sessions on both hosts and 13 base REPL
sessions on Windows. Linux owns those 13 base REPL sessions plus 6 Linux REPL
sessions and 17 selfhost REPL sessions, for 36. The focused LSP transcript-batch
contract is a delegated verifier with two generated valid entries; it is not a
fixture-directory corpus.

The exact-duplicate report currently contains nine two-row groups: each
formatter execution is deliberately replayed once to assert idempotence, with
the first execution as canonical owner and
`intentional-idempotence-replay` as the checked reason. There are no
cross-gate duplicates. Issue #4923 removed the former selfhost/public-tools LSP
corpus replay and is closed.

When changing a covered gate:

1. add or update the source annotation and its inventory row together;
2. run the checker and inspect its stale-count diff;
3. update the complete count block and any affected child-corpus expectation;
4. inspect `target/cli-gate-coverage/duplicates.tsv`; if a new exact duplicate
   is not an intentional replay with a clear owner, file a focused removal issue;
5. run `scripts/check-cli-gate-coverage.sh --self-test` and the owning full gate.

CI owns one fast `CLI gate inventory and ownership` entry on both platforms.
It runs the checker self-tests and then the production inventory before the
expensive selfhost, public-tools, and Linux stage1-wrapper gates. A count diff,
missing annotation/row, bad owner, unexplained duplicate, or child fixture
count mismatch fails CI without removing or skipping any underlying invocation
or assertion.

Use `scripts/fetch-stage0.sh <stage0-tag>` to pin an immutable artifact. The
script downloads the host platform asset, verifies the file is non-empty,
checks `SHA256SUMS` when the release provides it, and installs the command under
`target/stage0/`. It uses release asset URLs instead of fetching git tags, so the
mutable `stage0-latest` tag cannot be stale or clobber a local tag.

The complete local verification gate is:

```sh
scripts/ci-verify.sh
```

That script fetches `stage0-latest` when `TYPELISP_BIN` is unset and treats it
as the seed compiler. The seed performs the single compiler build of the flow:
the stage1->stage2->stage3 bootstrap fixpoint in `check-bootstrap-fixpoint.sh`
over `src/main.tl`.
Every remaining gate then runs on the captured stage2 compiler — the
branch-built full CLI — after a fail-closed probe confirms it can compile,
assemble, link, and run a native program on the host (`as`/`ld` on Linux,
`clang`/`lld-link` on Windows).

The verify-*/check-* scripts fetch the published stage0 when `TYPELISP_BIN` is
unset (via `scripts/lib-stage0.sh`); CI always passes `TYPELISP_BIN`
explicitly.

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
Before each self-host generation after stage1, the preceding compiler builds
the exact 42-module embedded source manifest into `stdlib.tlci`. The generated
compiler includes those bytes, maps them with the production W^X loader, and
the bootstrap smoke requires `typelisp inspect embedded:stdlib.tlci` to register
all 92 current macro identities. `verify-embedded-stdlib-tlci.sh` separately
checks byte determinism and proves that a source-only mutation changes the
image. The entries remain deterministic native registration shells until the
general macro-body lowering tracked by #2658 lands.

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

The bootstrapped stage2 compiler captured by the CI gate is the full
`src/main.tl` toolchain binary, so a single artifact serves every gate:
the compile-path corpora (deterministic assembly, selfhost compile manifest,
safety corpus, native integration corpus, examples, stdlib module/fixture
verifier) assemble and link with the host toolchain after stage2 emits
assembly, and the host-action gates (public `build`/`run`/package behavior,
chooser smoke, `doc`, `test`, fmt/lint, REPL/LSP public tools) run the same
stage2 binary directly on both Linux and Windows.

### Runtime-gap markers

The gate runs every check with a freshly bootstrapped stage2 compiler, so
source-only selfhost changes always run: there is no "skip until the published
stage0 catches up" mechanism, and a test that fails to build fails the gate.

For a stdlib runnable fixture with a narrowed runtime-only blocker, use
`requires-runtime-gap:<host>:#NNNN:<stderr-substring>` as the sixth
`scripts/verify-stdlib.sh` manifest field, where `<host>` is `linux`,
`windows`, or `all`. That marker skips only on the named host when the row
builds, exits with the wrong status, and stderr contains the tracked substring.
If the row starts passing on that host, the verifier reports that the marker
should be removed.

For new selfhost tests:

- Put structural compiler checks next to the owning module as small helpers or a
  `*-self-test` function.
- Prefer inline `(test ...)` items for new source-local runnable checks when a
  generated test harness is enough.
- Add a `*_smoke.tl` driver when the module should be executable through the
  compiler boundary.
- Add compile/symbol smoke coverage to `src/compile_manifest.txt` for new
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
the CI runner exercises the same import graph reviewers see locally. The
same script also owns host-specific backend/compiler-driver fixture checks that
are too low-level for a manifest row.

For Windows import-only regressions that fail before a native executable is
linked, use the published stage0 directly from PowerShell:

```powershell
tools\stage0\typelisp.exe run src\compiler_parse_core.tl --stdlib-root stdlib --stdlib-root src
tools\stage0\typelisp.exe run src\compiler_backend_tests.tl --stdlib-root stdlib --stdlib-root src
```

### Assembly shape gates

`scripts/verify-asm-shape-gates.sh` owns Linux opt2 assembly-shape assertions
for performance-sensitive regalloc/backend fixtures. Use this layer when a
native integration fixture can still return the right exit code while silently
falling back to slow codegen. The script compiles each fixture with the selected
CI compiler, extracts the intended function body, and checks for the fast shape
and the absence of known slow markers.

### Selfhost native generated programs

`scripts/verify-native-link-linux.sh` covers Linux-only cases where the selfhost
compiler emits assembly that must then assemble, link, and run as a native
executable. It builds `src/main.tl` and drives its `compile` subcommand to
verify generated file-to-file assembly for multi-file imports, stdlib imports,
runtime helpers, dynamic arrays, traps, and stack-argument call shape, plus the
direct-object (no-assembler) ELF link path via `cli build --direct`.

This runner is intentionally separate from the plain integration manifest:
manifest rows cover source programs built by the public compiler, while this
script covers generated-program behavior where the generated `.s` is the test
artifact.

### Stdlib documentation gate

`scripts/verify-stdlib-docs.sh` discovers every `stdlib/*.tl` module, requires
module and item documentation comments, generates Markdown through
`typelisp doc`, and runs `typelisp doc --test` with `--stdlib-root`. It is a
command-tier gate, so the Linux CI lane runs it through the selected
host-action CLI compiler when the doc command is available; otherwise the
explicit fallback/skip path is tied to #1662 and #1437.

### Repository doctest gate

`scripts/verify-doc-tests.sh` discovers documented `.tl` files under
`stdlib/`, `src/`, `examples/`, and `tests/` by scanning for public
canonical `;#`/`;:` doc comments or TypeLisp fenced examples, then runs
one `typelisp doc --test --batch <listfile>` process with `--stdlib-root`.
This gate does not use a hand-maintained file manifest, so adding documented
TypeLisp source with fenced examples automatically adds doctest coverage. In
CI command-tier lanes it runs through the compiler selected by
`scripts/ci-verify.sh`; runnable doctest files are required and executed on both
Linux and Windows.

### Repository inline-test gate

`scripts/verify-inline-tests.sh` discovers `.tl` files with top-level
`(test ...)` items under `src/`, `stdlib/`, `tests/integration/`,
`tools/`, `tests/inline/`, and `examples/`. It type-checks the discovered files
with one batched `test --check --batch` invocation, preserving per-file counts,
then runs each generated inline-test harness with `--stdlib-root`, reporting the
source path and test-runner output in CI logs. This gate is separate from
doctests, manifest corpora, and smoke drivers so source-owned checks can be
added next to the declarations they exercise.

### Stdlib API site

`tools/doc-site/doc_site.tl` builds a static language-reference and stdlib/API HTML
directory from `README.md`, `SPEC.md`, and the explicit top-level stdlib
manifest owned by the selfhost source. The local command is:

```sh
typelisp run tools/doc-site/doc_site.tl -- target/site
```

The generated directory contains `index.html`, `readme.html`, `spec.html`,
`stdlib.html`, `typelisp-docs.css`, and one deterministic `stdlib-*.html` page
for each manifested top-level stdlib module. `README.md` and `SPEC.md` are
rendered through the constrained selfhost Markdown renderer: supported blocks
become HTML, source-repository Markdown links are rewritten to generated pages
or GitHub source links, and unsupported Markdown syntax is emitted as escaped
literal text. The smoke driver `tools/doc-site/doc_site_smoke.tl` checks the
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
verification gate `scripts/ci-verify.sh` (wired in
[`../.github/workflows/ci.yml`](../.github/workflows/ci.yml)). Both jobs first
build a fresh `src/main.tl` binary from the published stage0 compiler and
smoke-test public `compile`, `build`, `run`, package build, staticlib build, and
the work-queue chooser through `typelisp run`. The Linux job then bootstraps a
compile-only stage1 compiler and runs deterministic assembly, the selfhost
compile manifest, borrowed-str source checks, the safety corpus, native
integration manifests, standalone examples, and stdlib modules/fixtures through
that bootstrapped artifact. Command-tier gates such as public-tool host-action
coverage, stdlib documentation, doctests, inline tests, docs Pages build,
native link generated programs, and the external selfhost corpus use their
explicit seed/fresh-cli fallback or skip paths until #1662 and related resource
blockers are closed. The Windows job runs host-supported gates against the
published stage0 compiler, verifies the fresh CLI build/run smoke, runs the
Windows bootstrap stage2/stage3 fixpoint when staged runtime symbols are present,
and explicitly skips the Linux-only src/docs checks.

CI sets `TYPELISP_CI_TIMING=1` for that serial verification flow. Each host
uploads one compact `ci-timing-<host>` TSV artifact with columns `gate`,
`case_or_chunk`, `phase`, `elapsed_ms`, `exit`, and `host`; the job log prints
only aggregate phase totals and the ten slowest rows. Detailed rows cover gate
totals plus integration stage/compile/assemble/link/run/assert phases,
build-invariance compiles, lint and selfhost-manifest chunks, inline-test batch
and per-file work, and CLI helper cases. Timestamps come from a monotonic clock,
and labels never include command lines, absolute credentials, or source text.
Local runs remain uninstrumented unless the same environment variable is set.

The Linux timing-budget gate requires exactly one successful
`TypeLisp source lint / all / gate` row and caps it at 60,000 ms. The cap is
deliberately well above the post-#5548 hosted Linux runtime so ordinary runner
noise does not fail healthy changes, while still catching a multi-fold
regression toward the former minute-scale quadratic source scans. The budget
consumes the row already recorded by `ci-verify.sh`; it does not run the
compiler or change the lint corpus and its 32-file batches. To diagnose a lint
regression locally with the same gate and a chosen compiler, time:

```sh
time env TYPELISP_BIN="$tl" scripts/check-tl-lint.sh
```

When a local or downloaded CI timing artifact is available, replay the exact
budget validation with
`scripts/check-ci-timing-budgets.sh target/ci-timing/linux.tsv`.

For a selfhost compiler change, a typical local check (after
`scripts/fetch-stage0.sh`, with `tl=target/stage0/typelisp[.exe]`) is:

```sh
$tl fmt --check src/<changed>.tl
TYPELISP_BIN=$tl ./scripts/verify-selfhost-compile-manifest.sh
TYPELISP_BIN=$tl ./scripts/check-tl-format.sh
TYPELISP_BIN=$tl ./scripts/check-tl-lint.sh
TYPELISP_BIN=$tl ./scripts/verify-public-tools.sh
TYPELISP_BIN=$tl ./scripts/verify-stdlib-docs.sh
TYPELISP_BIN=$tl ./scripts/verify-doc-tests.sh
TYPELISP_BIN=$tl ./scripts/verify-inline-tests.sh
TYPELISP_BIN=$tl ./scripts/check-codegen-target-parity.sh
scripts/ci-verify.sh
```

`scripts/check-tl-lint.sh` runs one batched `typelisp lint --check` over tracked
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
- Use inline `(test ...)` items for source-owned runnable checks; they are
  picked up automatically by `scripts/verify-inline-tests.sh`.
- Keep `src/compile_manifest.txt` in sync with top-level selfhost sources
  and compile/symbol smoke expectations.
- Prefer naming conventions and representative examples in docs and comments;
  avoid maintaining long file lists that will go stale.
- Run the focused tests for the layer touched, plus `typelisp fmt --check`.
