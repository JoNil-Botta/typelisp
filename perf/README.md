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

Benchmark metrics are exact: `current != baseline` fails and the baseline must
ratchet in the same PR. The self-compile metric has a documented 0.5%
cross-runner tolerance (`TYPELISP_IR_SELF_COMPILE_TOLERANCE_PPM=5000`) because
WSL and GitHub-hosted Linux cachegrind counts differ even with fixed paths and a
clean measured environment. Deltas outside that tolerance fail and must be
accepted by updating the committed baseline.

The checker builds a fresh full CLI stage1 and stage2 under
`target/instruction-count-check` and measures that fixed stage2 compiler. The
default per-PR subset is `self_compile` plus `arith_loop`, `array_sum`,
`hashmap_churn`, `hashmap_grow`, `hashmap_insert`, `hashmap_get`, and
`spmd_reduce`, each with one cachegrind run.

The heavy nightly workflow measures `spmd_map`, `spmd_mask`, `spmd_zip`,
`spmd_short_tail`, and `string_scan` as benchmark-only cases with one
cachegrind run. Heavy improvements and regressions are visible in the scheduled
workflow; accept intentional changes by committing an explicit
`perf/insn-exec-heavy-baseline.tsv` refresh.
