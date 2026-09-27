# Performance baselines

The checked tables in this directory, and the gates and scripts that own them:

| File | Owner |
| --- | --- |
| `insn-exec-baseline.tsv` | `linux-instruction-count-baseline` (`scripts/check-instruction-counts.sh`) |
| `insn-exec-heavy-baseline.tsv` | `linux-heavy-instruction-count-baseline` (the same script) |
| `benchmark-ci-cases.tsv` | suite membership for the benchmark, optimizer-corpus and instruction-count gates |
| `compiler-scaling-budgets.tsv` | `linux-compiler-scaling-budgets` (`scripts/check-compiler-scaling.sh`) |
| `spmd-mode-insn-baseline.tsv`, `spmd-mode-support.tsv` | opt-in `scripts/measure-spmd-mode-instruction-counts.sh` |

Measured deltas belong in the PR that changes a row, not in this file.

## Instruction-count baselines

`perf/insn-exec-baseline.tsv` and `perf/insn-exec-heavy-baseline.tsv` are the
committed cachegrind `Ir` baselines for the required Linux per-PR performance
gates. The first covers `self_compile` and the `instruction-main` cases of
`perf/benchmark-ci-cases.tsv` (the twelve compiler-derived kernels plus
`pure_call_join` and `loop_call_literal`); the second covers the
`instruction-heavy` cases, benchmark rows only. Explicit `--benchmarks` subsets
are scoped against the selected cases even when a baseline carries additional
rows.

Benchmark metrics are exact: `current != baseline` fails in either direction,
and an intentional change is accepted by committing the refreshed rows in the
same PR. Both improvements and regressions therefore block the PR that
introduces them.

### Refreshing

Absolute `self_compile` counts are owned by GitHub-hosted Linux CI. A local
Linux or WSL refresh may update benchmark rows only:

```sh
scripts/check-instruction-counts.sh --update-baseline --benchmarks-only
```

That partial refresh preserves the checked `self_compile` row. An update
selection that includes `self_compile` is rejected outside GitHub Actions, so a
host offset cannot silently enter the baseline. Ratchet an intentional compiler
change from the exact `current` value printed by the Linux CI gate and commit it
in the same PR.

Refresh the heavy baseline with the gate's own selection:

```sh
scripts/check-instruction-counts.sh \
  --update-baseline \
  --baseline perf/insn-exec-heavy-baseline.tsv \
  --benchmarks spmd_map,spmd_mask,spmd_zip,spmd_short_tail,string_scan \
  --benchmarks-only \
  --runs 1 \
  --output target/instruction-count-heavy
```

### `self_compile`

TypeLisp benchmark rows reproduce exactly across the supported WSL/Linux and
GitHub-hosted Linux environments for a fixed compiler and command.
`self_compile` is different: it deliberately retains full-process measurement,
and its absolute count is environment-specific. Repeated runs on one host are
stable, so a local reviewer can measure a compiler change as a same-host delta,
but must not compare a local absolute value with the checked CI baseline:

```sh
# Run on the base tree.
scripts/measure-instruction-counts.sh \
  --self-compile-only --opt-level 1 --runs 1 \
  --output target/instruction-count-base

# Run the same command on the branch tree, changing only --output.
scripts/measure-instruction-counts.sh \
  --self-compile-only --opt-level 1 --runs 1 \
  --output target/instruction-count-branch
```

Compare the `self_compile/compile_cli_opt1` rows in the two `summary.tsv`
files. `check-instruction-counts.sh` renders a local absolute self-compile row
as `local-absolute-unverified` and does not gate it; benchmark rows remain exact.
In GitHub Actions the checker applies a 0.5% self-compile tolerance
(`TYPELISP_IR_SELF_COMPILE_TOLERANCE_PPM=5000`) against the CI-owned baseline.
Intentional exact changes should still be reported and ratcheted rather than
treated as runner noise.

`--self-compile-only` measures no benchmark rows, so it neither requests
scalar-fair measurement nor checks for it, and its `--update-baseline`
preserves every benchmark row untouched. The `self_compile` optimizer level is
selected by `--opt-level` (default 1) and recorded in the row name.

### What the checker measures

Unless `TYPELISP_IR_CHECK_COMPILER` names a prebuilt compiler (CI passes its
bootstrap stage2), the checker builds a fresh full CLI stage1 and stage2 under
`target/instruction-count-check` and measures that fixed stage2 compiler.
Benchmark binaries are built at **opt-level 2**, so the TypeLisp-vs-C rows are
a release-vs-release comparison (TypeLisp opt2 against `clang -O2`); override
with `TYPELISP_IR_BENCH_OPT_LEVEL`. A selected benchmark case must contain both
`bench.tl` and `baseline.c`.

TypeLisp deliberately does not auto-vectorize ordinary loops. Explicit SPMD
(`foreach`, `spmd-reduce`, and `spmd-scan`) is the data-parallel model.
Accordingly, every TypeLisp row (`benchmark/typelisp/<name>`) must carry its
scalar-fair counterpart `benchmark/c-scalar/<name>`, built with
`clang -O2 -fno-vectorize -fno-slp-vectorize`, and `check-instruction-counts.sh`
enforces that pairing. The measurement also runs `benchmark/c/<name>` with
ordinary `clang -O2` auto-vectorization, making the auto-vectorizer gap visible;
`ratios.tsv` reports both `typelisp_over_clang_scalar_x` and
`typelisp_over_clang_auto_x`. A baseline opts into gating the auto-vectorized
row by carrying `benchmark/c/<name>` rows: the default baseline gates only the
TypeLisp and scalar-fair rows, while the heavy baseline keeps them. Every
measured run must also reproduce exact stdout, stderr, and exit status across
TypeLisp, auto-vectorized C, and scalar-fair C.

C baselines are compiled with `benchmarks/cachegrind-region.c` and run with
Cachegrind instrumentation off until the C `main` boundary. This excludes
dynamic-loader and PIE startup while retaining the benchmark, libc work reached
by the benchmark, and process-exit path. The C harness requires a Cachegrind
version and development header that provide
`CACHEGRIND_START_INSTRUMENTATION`. Its self-test compiles binaries with
different constructor workloads and requires identical nonzero measured-region
counts across both workloads and a repeated invocation; it fails with an
explicit unsupported-environment diagnostic if the request is unavailable:

```sh
scripts/measure-instruction-counts.sh --self-test
```

A clang, libc, or Valgrind change that alters instructions executed from `main`
onward is still a real, reviewable C comparison change; only pre-`main` loader
startup is excluded.

### Suite membership

`perf/benchmark-ci-cases.tsv` assigns positive membership to the Linux generic
`benchmark` suite, the `optimization-opt2` optimizer-corpus suite, and the
`instruction-main` and `instruction-heavy` suites. `scripts/lib-benchmark.sh`
enforces that no `instruction-main` case is also in `benchmark` or
`optimization-opt2`, and no `instruction-heavy` case is also in `benchmark`:
their measured execution already supplies output parity. Local `--cases` and
`--filter` selections are independent of CI membership.

## Compiler scaling budgets

`perf/compiler-scaling-budgets.tsv` is checked by the required Linux gate
`scripts/check-compiler-scaling.sh`. The fixed-input instruction counts above
cannot see a compiler cost that is acceptable at today's sizes and quadratic in
the size of one function, struct or module; this gate measures growth directly.

`tools/compiler-scaling` generates a deterministic program for a dimension and
a size. One dimension varies one property and a size only changes how many
units there are, never what a unit does:

| dimension | varies | each unit |
| --- | --- | --- |
| `decls` | declaration count | one small function, all reachable from `main` through eight-way callers |
| `cfg` | size of one function and its CFG | one two-armed branch on a running value, then a mask |
| `fields` | width of one struct | one `i64` field, initialized once and read once |

Every program checks itself: the generator evaluates the same arithmetic while
it emits the source, and `main` returns 42 only if the compiled program
reproduces that value. The gate builds and runs every program before it
measures anything, so a miscompiled or substituted input is a failure, not a
data point.

For each budget row the gate measures the compiler under Cachegrind at three
sizes `S < M < L` and derives two numbers in which the compiler's fixed
start-up cost cancels:

- **marginal**: `(Ir(L) - Ir(M)) / (L - M)`, instructions per added unit;
- **growth**: that marginal cost divided by `(Ir(M) - Ir(S)) / (M - S)`. It is
  1.0 for a linear cost and, with sizes in ratio 1:2:4, 2.0 for a quadratic one.

Because both are differences of counts on one binary, the host's environment
and paths do not reach them, so a local run reproduces the CI values. A row
fails when the marginal cost moves more than 10% or the growth more than 0.10
from its checked value, **in either direction**, matching the instruction-count
baselines: an improvement is accepted by committing the refreshed row.

```sh
scripts/check-compiler-scaling.sh target/bootstrap-fixpoint/stage3
scripts/check-compiler-scaling.sh --update-budgets target/bootstrap-fixpoint/stage3
```

`--update-budgets` rewrites only the two measured columns. Review the diff: a
changed number needs its measured cause in the PR, and a baseline refresh never
justifies a regression. A row whose growth is not linear names the issue that
owns the defect in its `owner` column; the PR that fixes the defect refreshes
the row, which turns the fix into a permanent regression check. New dimensions
and phases are new rows; do not widen the tolerances to admit a slower
compiler. The complete gate builds the generator, validates 12 programs and
runs 27 Cachegrind measurements.

This is the compiler-scaling half of #7773. It does not replace the
self-compile row or the memory checks: it bounds how cost grows, not how large
it is on the compiler's own sources.

## SPMD scalar/AVX2 mode matrix

`scripts/measure-spmd-mode-instruction-counts.sh` is the opt-in deterministic
mode comparison for the seven SPMD benchmarks. It builds TypeLisp explicitly at
`--opt-level 2 --backend-mode scalar|avx2`; scalar rows are paired with
`clang -O2 -fno-vectorize -fno-slp-vectorize`, while AVX2 rows are paired with
auto-vectorized `clang -O2 -mavx2 -mno-avx512f`. Thus each
benchmark/mode/implementation row lives in the same checked
`perf/spmd-mode-insn-baseline.tsv` table: scalar measures like-for-like codegen,
and AVX2 measures the explicit TypeLisp SPMD backend against clang's
auto-vectorized end-state target. Every measured pair must return the same exit
status. The checked support contract is `perf/spmd-mode-support.tsv`; an
unsupported TypeLisp row must fail with its exact recorded lowering diagnostic
and is emitted as `unsupported`, never as a missing or zero count.

Run the full local matrix from Linux or WSL and compare it with the committed
`perf/spmd-mode-insn-baseline.tsv`:

```sh
TYPELISP_BIN=target/stage0/typelisp \
  scripts/measure-spmd-mode-instruction-counts.sh \
  --runs 1 --check-baseline
```

Use `--cases spmd_shuffle --modes scalar,avx2` for a focused run and
`--update-baseline` only for an intentional full-matrix refresh. Output under
`target/spmd-mode-instruction-counts/` includes compiler/tool/flag metadata,
raw runs, stable summaries, per-benchmark TypeLisp/clang ratios, and per-mode
geomeans. Fast mutation coverage for mode selection, C flags, unsupported
rows, missing/unstable counts, ratios, and geomeans is available cross-platform:

```sh
scripts/measure-spmd-mode-instruction-counts.sh --self-test
```

AVX-512 is never run under cachegrind because Valgrind 3.22 raises SIGILL and
records only startup instructions, so AVX-512 has no instruction-count
baseline.

The opt-in ISPC comparison corpus (`scripts/measure-ispc-spmd.sh`) is
report-only and is not mixed into these tables; see
[`benchmarks/ispc/README.md`](../benchmarks/ispc/README.md).

## Optimizer pass-firing census

`scripts/measure-pass-firing.sh <compiler>` compiles the benchmarks, examples,
integration and inline tests, the `tools/` programs and `src/main.tl` at
`--opt-level 2` and counts, per optimizer pass slot and program, the functions
the slot changed (`firing.tsv`); `summary.tsv` marks slots that change code only
in benchmark programs. The script header describes its exact (IR dump diff) and
counts (trace-only) methods and their limits.

## Compile-profile optimizer escape capture

Use the compile-profile verifier to build a profile-enabled CLI, then capture an
optimized self-compile stderr log:

```sh
scripts/verify-compile-profile.sh
target/compile-profile-verify/<host>/typelisp-profile compile src/main.tl \
  -o target/compile-profile-verify/<host>/self-profile.s \
  --target <target> \
  --cfg <host-cfg> \
  --stdlib-root stdlib \
  --stdlib-root src \
  --opt-level 1 \
  2> target/compile-profile-verify/<host>/self-profile.stderr
grep -E 'compile-profile\|optimize\.functions\||compile-profile-detail\|optimize\.escape\.' \
  target/compile-profile-verify/<host>/self-profile.stderr
```

Use the same target and cfgs that match the host being measured. The escape rows
are `compile-profile-detail|optimize.escape.<phase>|elapsed_ms|opt_level|function`
with phases `body`, `dce_escape`, `compact`, `clone`, and `restore`.

## CI timing artifacts

Pull-request CI uploads one `ci-timing-Linux` and one `ci-timing-Windows`
artifact per run (`target/ci-timing/<host>.tsv`, written by `ci-verify.sh` when
`TYPELISP_CI_TIMING=1`). They record every gate's wall time and finer rows such
as the four build-invariance selfhost compiles
(`opt1-built:selfhost_main_opt1`, `opt2-built:selfhost_main_opt2`, ...). They
are evidence for performance work; CI applies no wall-clock budget to them.
Exact instruction counts guard performance instead. Use
`scripts/benchmark-compile-cli.sh` for phase-level local investigation of a
compile-time change.
