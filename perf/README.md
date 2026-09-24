# Instruction-count baseline

The opt-in pinned TypeLisp/ISPC corpus uses
`scripts/measure-ispc-spmd.sh`. Its static kernel-symbol reports and geomeans
are report-only and fingerprint both binaries and flags. They are intentionally
not mixed into the checked cachegrind tables below; the instruction-count
runners do not accept arbitrary ISPC binaries.

`perf/insn-exec-baseline.tsv` and `perf/insn-exec-heavy-baseline.tsv` are the
committed cachegrind `Ir` baselines for the required Linux per-PR performance
gates. The first covers the default compiler and benchmark subset; the second
covers the five heavier benchmark cases without rebuilding the branch compiler.

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

Refresh the required heavy benchmark baseline with:

```sh
scripts/check-instruction-counts.sh \
  --update-baseline \
  --baseline perf/insn-exec-heavy-baseline.tsv \
  --benchmarks spmd_map,spmd_mask,spmd_zip,spmd_short_tail,string_scan \
  --benchmarks-only \
  --runs 1 \
  --output target/instruction-count-heavy
```

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
The script prints this distinction before doing a local self-compile
measurement.

C baselines are compiled with `benchmarks/cachegrind-region.c` and run with
Cachegrind instrumentation off until the C `main` boundary. This excludes
dynamic-loader and PIE startup while retaining the benchmark, libc work reached
by the benchmark, and process-exit path. The C harness requires a Cachegrind
version and development header that provide
`CACHEGRIND_START_INSTRUMENTATION`; its self-test fails with an explicit
unsupported-environment diagnostic if the request is unavailable. Run it with:

```sh
scripts/measure-instruction-counts.sh --self-test
```

The self-test compiles binaries with different constructor workloads and
requires identical nonzero measured-region counts across both workloads and a
repeated invocation. Benchmark metrics remain exact: `current != baseline`
fails and the baseline must ratchet in the same PR. A clang, libc, or Valgrind
change that alters instructions executed from `main` onward is still a real,
reviewable C comparison change; only pre-`main` loader startup is excluded. In
GitHub Actions, the checker applies a 0.5% self-compile tolerance
(`TYPELISP_IR_SELF_COMPILE_TOLERANCE_PPM=5000`) against the CI-owned baseline.
Intentional exact changes should still be reported and ratcheted rather than
treated as runner noise.

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
and paths (which move an absolute count by a few hundred instructions) do not
reach them, so a local run reproduces the CI values. The rows move only when
the compiler does: the published stage0 from two merges earlier (`2381c505`)
measured every row within 0.4% marginal cost and 0.003 growth of the values
checked in from `70958577`. A row fails when the
marginal cost moves more than 10% or the growth more than 0.10 from its checked
value, **in either direction**, matching the instruction-count baselines: an
improvement is accepted by committing the refreshed row.

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
compiler. The complete gate (generator build, 12 validated programs and 27
Cachegrind runs) takes about one minute.

This is the compiler-scaling half of #7773. It does not replace the
self-compile row or the memory checks: it bounds how cost grows, not how large
it is on the compiler's own sources.

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

TypeLisp deliberately does not auto-vectorize ordinary loops. Explicit SPMD
(`foreach`, `spmd-reduce`, and `spmd-scan`) is the data-parallel model.
Accordingly, the per-PR scalar gate compares every TypeLisp row with scalar-fair
clang:

- `benchmark/c-scalar/<name>` uses
  `clang -O2 -fno-vectorize -fno-slp-vectorize` and is the scalar-fair codegen
  comparison.

The measurement also runs `benchmark/c/<name>` with ordinary `clang -O2`
auto-vectorization enabled, making the auto-vectorizer gap visible while SPMD
backends close it. The measurement report writes `ratios.tsv` with both
`typelisp_over_clang_scalar_x` and `typelisp_over_clang_auto_x`, but the default
`perf/insn-exec-baseline.tsv` deliberately gates only the TypeLisp and
scalar-fair rows. Every measured benchmark run must also reproduce exact
stdout, stderr, and exit status across TypeLisp, auto-vectorized C, and
scalar-fair C; repeated runs must reproduce the same observable output.

TypeLisp-generated executables use `benchmark/typelisp/<name>`.
A selected benchmark case must contain both `bench.tl` and `baseline.c`;
unpaired benchmark directories are skipped only when no explicit benchmark
filter or case list selected them.

Every TypeLisp baseline row must carry its `benchmark/c-scalar/<name>`
counterpart, and `check-instruction-counts.sh` enforces that contract. A
baseline opts into gating the diagnostic auto-vectorized row by carrying
`benchmark/c/<name>` rows; the scheduled heavy baseline retains those rows.

`--self-compile-only` is the one leg that measures no benchmark rows, so it
neither requests scalar-fair measurement nor checks for it, and its
`--update-baseline` preserves every benchmark row untouched.

Benchmark binaries are built at **opt-level 2** so the TypeLisp-vs-C rows are a
release-vs-release comparison (TypeLisp opt2 against `clang -O2`). Override with
`TYPELISP_IR_BENCH_OPT_LEVEL`. This is independent of the `self_compile` metric,
whose optimizer level is selected separately by `--opt-level` (default 1) and
recorded in its row name (`self_compile/compile_cli_opt1`).

The checker builds a fresh full CLI stage1 and stage2 under
`target/instruction-count-check` and measures that fixed stage2 compiler. The
default per-PR subset is `self_compile` plus TypeLisp and scalar-clang rows for
the twelve kernels derived from compiler self-compilation: `cfg_domloops`,
`gvn_table`, `intern_table`, `lex_source`, `liveness_scan`, `peephole_lines`,
`read_sexpr`, `callgraph_scc`, `ssa_construct`, `sccp_lattice`,
`regalloc_greedy`, and `asm_render`, each with one cachegrind run. Explicit benchmark subsets are
scoped against those selected cases even when the baseline carries additional
rows. Alternate baseline files such as the scheduled heavy corpus retain their
own checked row policy.

`perf/benchmark-ci-cases.tsv` assigns positive membership to the Linux generic
benchmark, opt2 optimizer-corpus, and instruction-count suites. The seventeen
instruction-count workloads are absent from the generic benchmark suite, and
the twelve main workloads are absent from the separate opt2 suite. Their measured
execution supplies both output parity and instruction-count coverage; local
case and filter selections remain independent of CI membership.

The same required Linux PR leg reuses its already bootstrapped stage2 compiler
for a benchmark-only pass over `spmd_map`, `spmd_mask`, `spmd_zip`,
`spmd_short_tail`, and `string_scan`, checked exactly against
`perf/insn-exec-heavy-baseline.tsv`. This adds one `Linux heavy
instruction-count baseline` gate row to the `ci-timing-Linux` artifact without
repeating the compiler bootstrap. Heavy improvements and regressions therefore
block the PR that introduces them; accept intentional changes by committing an
explicit `perf/insn-exec-heavy-baseline.tsv` refresh.

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
grep -E 'compile-profile\|optimize\.functions\||compile-profile-detail\|optimize\.escape\.(body|compact|clone|restore)\|' \
  target/compile-profile-verify/<host>/self-profile.stderr
```

Use the same target and cfgs that match the host being measured. The escape rows
are `compile-profile-detail|optimize.escape.<phase>|elapsed_ms|opt_level|function`
with phases for `body`, `compact`, `clone`, and `restore`.

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
