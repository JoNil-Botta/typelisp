# Codegen hardware cycle reference

TypeLisp opt2 from compiler revision `dcd110ffd`, measured against Clang
23.1.3 on an AMD Ryzen 9 9950X pinned to logical CPU 12. The host used Linux
7.2.15-1-omarchy, glibc 2.44, Valgrind 3.25.1 and perf 7.2.11-1. Cycle
counts are the median of five whole-process user-mode samples.
Ratios are TypeLisp divided by Clang. The published CI Ir pins are
measured separately with Ubuntu Clang 18.

| Workload group | C reference | Pairs | Ir geomean | Cycle geomean |
| --- | --- | ---: | ---: | ---: |
| Realistic kernels | Scalar Clang `-O2` | 18 | 1.114× | 1.175× |
| Realistic kernels | Auto-vectorized Clang `-O2` | 18 | 1.121× | 1.179× |
| AVX2 SPMD | Clang `-O2 -mavx2 -mno-avx512f` | 8 | 1.980× | 2.150× |

## Realistic kernels and FP probes

The per-pair rows below use Clang `-O2 -fno-vectorize -fno-slp-vectorize`.

| Benchmark | Ir ratio | TypeLisp cycles | Clang cycles | Cycle ratio |
| --- | ---: | ---: | ---: | ---: |
| `cfg_domloops` | 1.262× | 175,827,660 | 160,943,035 | 1.092× |
| `gvn_table` | 1.078× | 351,971,806 | 253,776,190 | 1.387× |
| `intern_table` | 1.209× | 217,316,950 | 167,008,365 | 1.301× |
| `lex_source` | 0.846× | 305,508,899 | 254,012,862 | 1.203× |
| `liveness_scan` | 0.724× | 202,800,159 | 175,857,789 | 1.153× |
| `peephole_lines` | 0.853× | 204,779,219 | 106,622,197 | 1.921× |
| `read_sexpr` | 1.104× | 258,524,950 | 336,734,624 | 0.768× |
| `callgraph_scc` | 1.277× | 167,867,583 | 135,594,383 | 1.238× |
| `ssa_construct` | 1.403× | 202,404,274 | 201,861,622 | 1.003× |
| `sccp_lattice` | 1.326× | 405,229,081 | 202,167,793 | 2.004× |
| `regalloc_greedy` | 1.356× | 245,406,374 | 215,188,083 | 1.140× |
| `asm_render` | 1.068× | 533,043,726 | 339,543,699 | 1.570× |
| `opt_bytecode_vm` | 1.045× | 261,257,980 | 221,629,054 | 1.179× |
| `opt_crc32` | 0.806× | 493,753,924 | 498,491,083 | 0.990× |
| `opt_quicksort` | 1.015× | 647,038,614 | 638,992,811 | 1.013× |
| `graph_dijkstra` | 1.343× | 431,669,583 | 419,766,321 | 1.028× |
| `phys_nbody` | 1.333× | 170,776,593 | 212,880,933 | 0.802× |
| `route_http` | 1.404× | 97,482,826 | 93,180,049 | 1.046× |

### FP probes

| Benchmark | Ir ratio | TypeLisp cycles | Clang cycles | Cycle ratio |
| --- | ---: | ---: | ---: | ---: |
| `fp_taylor_exp` | 1.106× | 107,818,306 | 84,632,204 | 1.274× |
| `fp_mixed_recurrence` | 1.342× | 203,351,864 | 132,908,875 | 1.530× |

## Eight AVX2 SPMD pairs

| Benchmark | Ir ratio | TypeLisp cycles | Clang cycles | Cycle ratio |
| --- | ---: | ---: | ---: | ---: |
| `spmd_map` | 1.570× | 854,345,406 | 624,404,350 | 1.368× |
| `spmd_zip` | 1.169× | 1,173,364,407 | 904,262,218 | 1.298× |
| `spmd_reduce` | 1.182× | 588,729,652 | 318,668,326 | 1.847× |
| `spmd_scan` | 1.433× | 5,580,423,212 | 1,436,791,604 | 3.884× |
| `spmd_shuffle` | 3.631× | 958,915,635 | 354,217,266 | 2.707× |
| `spmd_short_tail` | 1.701× | 556,499,274 | 442,847,745 | 1.257× |
| `spmd_mask` | 2.444× | 1,131,869,760 | 409,393,034 | 2.765× |
| `spmd_foreach_2d` | 5.027× | 877,098,477 | 230,475,113 | 3.806× |

## Reproduction

Build the compiler with `scripts/ci-verify.sh --gates bootstrap-compiler`.
Choose a logical CPU that is free of other benchmark work.

```sh
compiler=target/bootstrap-fixpoint/stage2
cpu=12
kernels=$(awk -F '\t' '$1 == "realistic-kernel" {print $2}' \
    perf/benchmark-ci-cases.tsv | paste -sd , -)
taskset -c "$cpu" scripts/measure-instruction-counts.sh \
    --benchmarks-only --cases "$kernels,fp_taylor_exp,fp_mixed_recurrence" \
    --c-scalar --runs 1 --cycles "$compiler"
taskset -c "$cpu" scripts/measure-spmd-mode-instruction-counts.sh \
    --modes avx2 --runs 1 --cycles "$compiler"
```
