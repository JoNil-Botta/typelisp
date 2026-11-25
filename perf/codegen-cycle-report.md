# Codegen hardware cycle reference

TypeLisp opt2 from compiler revision `ceca35e77`, measured against Clang
23.1.3 on an AMD Ryzen 9 9950X pinned to logical CPU 14. The host used Linux
7.2.15-1-omarchy, glibc 2.44, Valgrind 3.25.1 and perf 7.2.11-1. Cycle
counts are the median of five whole-process user-mode samples.
Ratios are TypeLisp divided by Clang. The published CI Ir pins are
measured separately with Ubuntu Clang 18.

| Workload group | C reference | Pairs | Ir geomean | Cycle geomean |
| --- | --- | ---: | ---: | ---: |
| Realistic kernels | Scalar Clang `-O2` | 18 | 1.100× | 1.090× |
| Realistic kernels | Auto-vectorized Clang `-O2` | 18 | 1.107× | 1.096× |
| AVX2 SPMD | Clang `-O2 -mavx2 -mno-avx512f` | 8 | 1.059× | 0.983× |

## Realistic kernels and FP probes

The per-pair rows below use Clang `-O2 -fno-vectorize -fno-slp-vectorize`.

| Benchmark | Ir ratio | TypeLisp cycles | Clang cycles | Cycle ratio |
| --- | ---: | ---: | ---: | ---: |
| `cfg_domloops` | 1.255× | 167,496,578 | 157,360,507 | 1.064× |
| `gvn_table` | 1.076× | 206,072,154 | 158,918,662 | 1.297× |
| `intern_table` | 1.192× | 135,917,874 | 124,489,609 | 1.092× |
| `lex_source` | 0.846× | 183,547,691 | 185,268,937 | 0.991× |
| `liveness_scan` | 0.719× | 132,882,436 | 110,650,734 | 1.201× |
| `peephole_lines` | 0.854× | 104,589,188 | 99,745,458 | 1.049× |
| `read_sexpr` | 1.102× | 253,744,066 | 234,603,749 | 1.082× |
| `callgraph_scc` | 1.271× | 156,575,092 | 128,792,929 | 1.216× |
| `ssa_construct` | 1.370× | 189,089,149 | 168,535,302 | 1.122× |
| `sccp_lattice` | 1.308× | 205,413,370 | 167,152,550 | 1.229× |
| `regalloc_greedy` | 1.334× | 204,990,720 | 178,337,026 | 1.149× |
| `asm_render` | 1.067× | 299,265,268 | 271,100,972 | 1.104× |
| `opt_bytecode_vm` | 1.045× | 151,970,890 | 150,962,688 | 1.007× |
| `opt_crc32` | 0.806× | 484,568,920 | 484,733,198 | 1.000× |
| `opt_quicksort` | 1.015× | 564,318,910 | 552,464,307 | 1.021× |
| `graph_dijkstra` | 1.322× | 342,654,520 | 341,614,147 | 1.003× |
| `phys_nbody` | 1.191× | 168,729,271 | 160,992,108 | 1.048× |
| `route_http` | 1.392× | 92,546,174 | 92,230,071 | 1.003× |

### FP probes

| Benchmark | Ir ratio | TypeLisp cycles | Clang cycles | Cycle ratio |
| --- | ---: | ---: | ---: | ---: |
| `fp_taylor_exp` | 1.021× | 77,177,421 | 76,776,096 | 1.005× |
| `fp_mixed_recurrence` | 1.083× | 134,100,217 | 132,339,168 | 1.013× |

## Eight AVX2 SPMD pairs

| Benchmark | Ir ratio | TypeLisp cycles | Clang cycles | Cycle ratio |
| --- | ---: | ---: | ---: | ---: |
| `spmd_map` | 0.905× | 674,568,185 | 619,691,236 | 1.089× |
| `spmd_zip` | 0.979× | 999,253,421 | 803,366,749 | 1.244× |
| `spmd_reduce` | 1.200× | 173,755,125 | 319,062,383 | 0.545× |
| `spmd_scan` | 1.004× | 935,344,542 | 1,235,272,392 | 0.757× |
| `spmd_shuffle` | 1.186× | 341,700,993 | 379,841,333 | 0.900× |
| `spmd_short_tail` | 0.982× | 315,526,188 | 281,269,983 | 1.122× |
| `spmd_mask` | 1.097× | 360,835,581 | 312,568,479 | 1.154× |
| `spmd_foreach_2d` | 1.159× | 266,611,106 | 198,891,664 | 1.340× |

## Reproduction

Build the compiler with `scripts/ci-verify.sh --gates bootstrap-compiler`.
Choose a logical CPU that is free of other benchmark work.

```sh
compiler=target/bootstrap-fixpoint/stage2
cpu=14
kernels=$(. scripts/lib-benchmark.sh && benchmark_ci_case_csv "$PWD" realistic-kernel)
taskset -c "$cpu" scripts/measure-instruction-counts.sh \
    --benchmarks-only --cases "$kernels,fp_taylor_exp,fp_mixed_recurrence" \
    --c-scalar --runs 1 --cycles "$compiler"
taskset -c "$cpu" scripts/measure-spmd-mode-instruction-counts.sh \
    --modes avx2 --runs 1 --cycles "$compiler"
```
