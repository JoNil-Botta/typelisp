# Instruction-count baseline

The opt-in pinned TypeLisp/ISPC corpus uses
`scripts/measure-ispc-spmd.sh`. Its static kernel-symbol reports and geomeans
are report-only and fingerprint both binaries and flags. They are intentionally
not mixed into the checked cachegrind or host-keyed AVX-512 tables below; the
current retired-instruction runners do not accept arbitrary ISPC binaries.

`perf/insn-exec-baseline.tsv` and `perf/insn-exec-heavy-baseline.tsv` are the
committed cachegrind `Ir` baselines for the required Linux per-PR performance
gates. The first covers the default compiler and benchmark subset; the second
covers the five heavier benchmark cases without rebuilding the branch compiler.

Run this from Linux or WSL to refresh intentional count changes:

```sh
scripts/check-instruction-counts.sh --update-baseline
```

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

TypeLisp-generated cachegrind metrics, including `self_compile`, retain
full-process measurement and are deterministic across WSL and GitHub-hosted
Linux for a fixed compiler and command. C baselines are compiled with
`benchmarks/cachegrind-region.c` and run with Cachegrind instrumentation off
until the C `main` boundary. This excludes dynamic-loader and PIE startup while
retaining the benchmark, libc work reached by the benchmark, and process-exit
path. The C harness requires a Cachegrind version and development header that
provide `CACHEGRIND_START_INSTRUMENTATION`; its self-test fails with an explicit
unsupported-environment diagnostic if the request is unavailable. Run it with:

```sh
scripts/measure-instruction-counts.sh --self-test
```

The self-test compiles binaries with different constructor workloads and
requires identical nonzero measured-region counts across both workloads and a
repeated invocation. Benchmark metrics remain exact: `current != baseline`
fails and the baseline must ratchet in the same PR. A clang, libc, or Valgrind
change that alters instructions executed from `main` onward is still a real,
reviewable C comparison change; only pre-`main` loader startup is excluded. The
checker currently applies a 0.5% self-compile tolerance
(`TYPELISP_IR_SELF_COMPILE_TOLERANCE_PPM=5000`), but intentional exact changes
should still be reported and ratcheted rather than treated as runner noise.

## CI wall-clock compile budgets

Linux pull-request CI also gates the four selfhost compile rows already
recorded by `scripts/check-build-invariance.sh` in
`target/ci-timing/linux.tsv`. The gate adds no compiler invocations. It applies
generous absolute caps to catch uniform slowdowns and a scale-independent ratio
to catch disproportionate opt2 work:

| build-invariance row | cap |
| --- | ---: |
| `opt2-built:selfhost_main_opt1` | 25,000 ms |
| `opt1-built:selfhost_main_opt1` | 35,000 ms |
| `opt2-built:selfhost_main_opt2` | 55,000 ms |
| `opt1-built:selfhost_main_opt2` | 90,000 ms |

The `opt2-built:selfhost_main_opt2` /
`opt1-built:selfhost_main_opt1` ratio must be at most 2.5. The checker fails
closed on missing, duplicate, malformed, or unsuccessful rows:

```sh
scripts/check-ci-timing-budgets.sh target/ci-timing/linux.tsv
scripts/check-ci-timing-budgets.sh --self-test
```

Use `scripts/benchmark-compile-cli.sh` for phase-level local investigation when
the wall-clock gate fails. There is intentionally no retry path; the headroom,
absolute caps, and ratio provide flake resistance without masking regressions.

## Scheduled CI timing trends

The daily and manually dispatched `CI Timing Trends` workflow consumes the
existing `ci-timing-Linux` and `ci-timing-Windows` artifacts from successful
pull-request CI runs. It does not invoke the compiler or add work to PR CI.
Runs are considered newest-first, deduplicated by head SHA, and accepted only
as complete Linux/Windows artifact pairs. Stable gate-total rows
(`case_or_chunk=all`, `phase=gate`, `exit=0`) are analyzed separately for each
host and gate.

By default, the median of the newest 3 unique heads is compared with the
median of the preceding 20. A sustained regression is reported only when the
recent median is greater than 1.5 times the baseline median. The
hard-budgeted `stage2 opt1/opt2 build-invariance` gate is explicitly excluded
to avoid duplicate alerts. Windows, gate names, run links, medians, ratios,
and the newest-first series are retained in deterministic Markdown. Missing
per-gate history is reported without fabricating a baseline.

One marked issue titled `CI timing sustained regression alert` is created,
updated, or reopened while regressions exist. A recovered series receives a
recovery comment and the issue is closed. Regression detection itself exits
successfully; collection, API, artifact, or schema failures fail the scheduled
job visibly but cannot block pull requests.

Recent window, baseline window, factor, scan limit, and the newline-separated
gate denylist are configurable through `CI_TIMING_TREND_RECENT`,
`CI_TIMING_TREND_BASELINE`, `CI_TIMING_TREND_FACTOR`,
`CI_TIMING_TREND_RUN_LIMIT`, and `CI_TIMING_TREND_DENYLIST`. Analyze a
normalized history offline or run the synthetic suite with:

```sh
scripts/analyze-ci-timing-trends.sh --offline history.tsv report.md
scripts/analyze-ci-timing-trends.sh --self-test
```

TypeLisp deliberately does not auto-vectorize ordinary loops. Explicit SPMD
(`foreach`, `spmd-reduce`, and `spmd-scan`) is the data-parallel model.
Accordingly, the per-PR scalar gate compares every TypeLisp row with two clang
rows:

- `benchmark/c-scalar/<name>` uses
  `clang -O2 -fno-vectorize -fno-slp-vectorize` and is the scalar-fair codegen
  comparison.
- `benchmark/c/<name>` keeps ordinary `clang -O2` auto-vectorization enabled,
  making the auto-vectorizer gap visible while SPMD backends close it.

TypeLisp-generated executables use `benchmark/typelisp/<name>`. The measurement
report writes `ratios.tsv` with both
`typelisp_over_clang_scalar_x` and `typelisp_over_clang_auto_x`; all three
instruction-count rows are exact gate inputs in `perf/insn-exec-baseline.tsv`.
A selected benchmark case must contain both `bench.tl` and `baseline.c`;
unpaired benchmark directories are skipped only when no explicit benchmark
filter or case list selected them.

Benchmark binaries are built at **opt-level 2** so the TypeLisp-vs-C rows are a
release-vs-release comparison (TypeLisp opt2 against `clang -O2`). Override with
`TYPELISP_IR_BENCH_OPT_LEVEL`. This is independent of the `self_compile` metric,
whose optimizer level is selected separately by `--opt-level` (default 1) and
recorded in its row name (`self_compile/compile_cli_opt1`).

The checker builds a fresh full CLI stage1 and stage2 under
`target/instruction-count-check` and measures that fixed stage2 compiler. The
default per-PR subset is `self_compile` plus TypeLisp/auto-clang/scalar-clang
rows for `arith_loop`, `array_sum`, `borrowed_disjoint_store`, `hashmap_churn`,
`hashmap_grow`, `hashmap_insert`, `hashmap_get`, `spmd_reduce`,
`opt_quicksort`, `opt_crc32`, and `opt_bytecode_vm`, each with one cachegrind
run. Alternate baseline files such as the scheduled heavy corpus retain their
own checked row policy.

The same required Linux PR leg reuses its already bootstrapped stage2 compiler
for a benchmark-only pass over `spmd_map`, `spmd_mask`, `spmd_zip`,
`spmd_short_tail`, and `string_scan`, checked exactly against
`perf/insn-exec-heavy-baseline.tsv`. This adds one `Linux heavy
instruction-count baseline` gate row to the `ci-timing-Linux` artifact without
repeating the compiler bootstrap.

## Host-keyed AVX-512 retired instructions

Cachegrind 3.22 cannot execute this AVX-512 corpus: it SIGILLs and records only
startup work. Use the opt-in Linux/WSL hardware harness instead:

```sh
TYPELISP_BIN=target/stage0/typelisp \
  scripts/measure-spmd-avx512-instructions.sh --focused --cpu 4
TYPELISP_BIN=target/stage0/typelisp \
  scripts/measure-spmd-avx512-instructions.sh \
  --runs 11 --check-baseline --cpu 4
```

The harness requires runnable AVX-512F+BW+DQ and OS ZMM/opmask state. It builds
TypeLisp with explicit `--backend-mode avx512 --opt-level 2` and the static C
comparison with `clang -O2 -march=x86-64 -mavx512f -mavx512bw -mavx512dq
-mno-avx512vl -static`; it never uses `-march=native`. Before measuring, each
pair must match exit status, stdout, and stderr.

`tools/spmd-avx512-perf/counter.tl` calls `perf_event_open` directly, pins the
child to one logical CPU, starts the inherited user-space-only event on
`execve`, waits, and rejects unavailable, zero, multiplexed, or signal/SIGILL
results. There is no dependency on a distro-matched `perf`, Intel SDE, QEMU,
llvm-mca, or a C helper.

One warmup precedes 11 recorded runs. `metadata.tsv` records the complete
host/tool/flags/PMU contract; `runs.tsv`, `summary.tsv`, and `comparison.tsv`
record the raw counts, median/statistics/CV, TypeLisp-to-clang ratios, and
geomean. Rebuilt assembly must hash identically, and static vector/AVX-512
operand counts remain diagnostic columns—zero is visible and valid rather than
substituted for dynamic performance.

The committed `perf/spmd-avx512-retired-baseline.tsv` is keyed by a SHA-256 of
the counter source, OS/kernel, CPU identity and logical CPU, ISA tokens,
clang/as/ld versions, flags, and counter configuration. The 1000 ppm tolerance
is enforced only for an exact fingerprint; other hosts are report-only.
The baseline includes every supported benchmark, including measured
`spmd_mask/avx512` and `spmd_shuffle/avx512` rows.
Only a full 11-run measurement may update the baseline. The heavy hardware
measurement is never part of required correctness CI; only fast mutation
self-tests run there:

```sh
scripts/measure-spmd-avx512-instructions.sh --self-test
```

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

## Heavy compile RSS checks

Use `scripts/measure-compile-rss.sh` from Linux or WSL before reopening checked
program compaction work from #3863. The harness wraps real compiler invocations
with GNU `/usr/bin/time -v`, writes a stable TSV summary, and keeps command,
stdout, stderr, and time transcripts under `target/compile-rss/`. It fails
clearly when GNU time is not available.

Run the same workloads once with current `main` and once with the candidate
branch compiler, then compare `elapsed_ms`, `exit_code`, and `max_rss_kb` in
`target/compile-rss/measurements.tsv`:

```sh
TYPELISP_COMPILE_RSS_OUT=target/compile-rss-main \
  TYPELISP_BIN=target/main/typelisp \
  scripts/measure-compile-rss.sh --mode all
TYPELISP_COMPILE_RSS_OUT=target/compile-rss-candidate \
  TYPELISP_BIN=target/candidate/typelisp \
  scripts/measure-compile-rss.sh --mode all
```

The default `all` mode runs both required #3863 workloads:

```sh
scripts/measure-compile-rss.sh --mode single --input src/doc_test.tl <typelisp-bin>
scripts/measure-compile-rss.sh --mode manifest-chunk --chunk-id 0002 <typelisp-bin>
```

Manifest chunk ids are zero-based file ids. The required heavy chunk is
`0002`, which is human chunk 3. Keep the default manifest batch size at 16;
reducing the batch size hides the memory behavior being measured. If a different
output directory is useful for side-by-side runs, set `TYPELISP_COMPILE_RSS_OUT`.

The required Linux PR gate measures `spmd_map`, `spmd_mask`, `spmd_zip`,
`spmd_short_tail`, and `string_scan` as benchmark-only cases with one
cachegrind run. Heavy improvements and regressions therefore block the PR that
introduces them; accept intentional changes by committing an explicit
`perf/insn-exec-heavy-baseline.tsv` refresh.

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
records only startup instructions. Its separate measurement methodology is
tracked in [#4933](https://github.com/JoNil-Botta/typelisp/issues/4933).
