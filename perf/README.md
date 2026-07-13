# Instruction-count baseline

`perf/insn-exec-baseline.tsv` is the committed cachegrind `Ir` baseline for the
Linux per-PR performance gate. `perf/insn-exec-heavy-baseline.tsv` is the
separate nightly baseline for benchmark cases that are too slow for every PR.

Run this from Linux or WSL to refresh intentional count changes:

```sh
scripts/check-instruction-counts.sh --update-baseline
```

Refresh the nightly heavy benchmark baseline with:

```sh
scripts/check-instruction-counts.sh \
  --update-baseline \
  --baseline perf/insn-exec-heavy-baseline.tsv \
  --benchmarks spmd_map,spmd_mask,spmd_zip,spmd_short_tail,string_scan \
  --benchmarks-only \
  --runs 1 \
  --output target/instruction-count-heavy
```

TypeLisp-generated cachegrind metrics, including `self_compile`, are
deterministic across WSL and GitHub-hosted Linux for a fixed compiler and
command. Benchmark metrics are exact: `current != baseline` fails and the
baseline must ratchet in the same PR. The checker currently applies a 0.5%
self-compile tolerance (`TYPELISP_IR_SELF_COMPILE_TOLERANCE_PPM=5000`), but
intentional exact changes should still be reported and ratcheted rather than
treated as runner noise.

Comparison benchmark rows are split by implementation. TypeLisp-generated
executables use `benchmark/typelisp/<name>` and the paired deterministic
`clang -O2` C baseline uses `benchmark/c/<name>`. A selected benchmark case must
contain both `bench.tl` and `baseline.c`; unpaired benchmark directories are
skipped only when no explicit benchmark filter or case list selected them.

Benchmark binaries are built at **opt-level 2** so the TypeLisp-vs-C rows are a
release-vs-release comparison (TypeLisp opt2 against `clang -O2`). Override with
`TYPELISP_IR_BENCH_OPT_LEVEL`. This is independent of the `self_compile` metric,
whose optimizer level is selected separately by `--opt-level` (default 1) and
recorded in its row name (`self_compile/compile_cli_opt1`).

The checker builds a fresh full CLI stage1 and stage2 under
`target/instruction-count-check` and measures that fixed stage2 compiler. The
default per-PR subset is `self_compile` plus paired rows for `arith_loop`,
`array_sum`, `hashmap_churn`, `hashmap_grow`, `hashmap_insert`, `hashmap_get`,
`spmd_reduce`, `opt_quicksort`, `opt_crc32`, and `opt_bytecode_vm`, each with one
cachegrind run.

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

The heavy nightly workflow measures `spmd_map`, `spmd_mask`, `spmd_zip`,
`spmd_short_tail`, and `string_scan` as benchmark-only cases with one
cachegrind run. Heavy improvements and regressions are visible in the scheduled
workflow; accept intentional changes by committing an explicit
`perf/insn-exec-heavy-baseline.tsv` refresh.

## SPMD scalar/AVX2 mode matrix

`scripts/measure-spmd-mode-instruction-counts.sh` is the opt-in deterministic
mode comparison for the five SPMD benchmarks. It builds TypeLisp explicitly at
`--opt-level 2 --backend-mode scalar|avx2`; scalar rows are paired with
`clang -O2 -fno-vectorize -fno-slp-vectorize`, and AVX2 rows with
`clang -O2 -mavx2 -mno-avx512f`. Every measured pair must return the same exit
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

Use `--cases spmd_map --modes scalar,avx2` for a focused run and
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
