# Compact vector identity compile cost

Issue #5295 measures the incremental compiler work from one to five distinct
compact `(vector.vector T core)` identities. The paired fixtures demand the
same `new`, `push`, and `get` surface from every identity:

- `tests/integration/compile_profile_vector_one_core.tl`
- `tests/integration/compile_profile_vector_five_core.tl`

The diagnostic harness is:

```sh
TYPELISP_BIN=tools/stage0-linux/typelisp \
  scripts/measure-vector-instantiation-cost.sh --runs 1
```

It does not read or update `perf/insn-exec-baseline.tsv`.

## Current-main measurement

Measured on current main `579fc53f5e08e07fe764c7d6193258d34f09602e`
with its exact Linux stage0 artifact from workflow run `29664419394`,
Valgrind 3.22.0, and Linux x86-64 under WSL2.

| fixture | Cachegrind `Ir` | delta |
| --- | ---: | ---: |
| one compact identity | 305,091,082 | 0 |
| five compact identities | 356,101,734 | +51,010,652 (+16.719811%) |

The compile-profile allocation rows make the additional work visible at each
pipeline boundary. Elapsed milliseconds are intentionally omitted here because
they are scheduler-sensitive; the harness preserves them in its local TSV.

| phase | one allocation bytes | five allocation bytes | delta |
| --- | ---: | ---: | ---: |
| macro expansion | 1,581,752 | 2,986,384 | +1,404,632 |
| specialization | 121,952 | 174,960 | +53,008 |
| reachability prune | 1,737,768 | 1,812,504 | +74,736 |
| concrete typecheck | 3,559,480 | 4,944,776 | +1,385,296 |
| reachable-plan apply | 18,144 | 24,384 | +6,240 |
| declaration lowering | 1,113,880 | 1,752,664 | +638,784 |
| optimize | 655,712 | 2,435,056 | +1,779,344 |
| backend | 904,680 | 2,599,872 | +1,695,192 |
| total compile | 145,825,960 | 152,999,560 | +7,173,600 |

The deterministic counters attribute why those phases grow:

| counter | one | five | delta |
| --- | ---: | ---: | ---: |
| generated module materializations | 1 | 5 | +4 |
| generated module memo hits | 0 | 0 | 0 |
| generated catalog declarations constructed | 11 | 55 | +44 |
| generated declaration checks | 11 | 55 | +44 |
| functions before specialization | 106 | 150 | +44 |
| functions after specialization | 106 | 150 | +44 |
| declarations retained by reachability | 91 | 147 | +56 |
| functions retained by reachability | 23 | 63 | +40 |
| emitted IR functions | 23 | 63 | +40 |
| emitted IR blocks | 50 | 193 | +143 |
| emitted IR instructions | 245 | 985 | +740 |

The unchanged function count across specialization shows that this compact
vector pair is already concrete; its incremental specialization cost is scan
and bookkeeping rather than new specialized functions. Reachability removes
unused generated declarations only after all 11 declarations per identity have
been checked, preserving full-body diagnostics.

Refs #5250, #4523, and #5262.
