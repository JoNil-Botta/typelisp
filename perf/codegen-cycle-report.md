# Codegen hardware cycle reference

TypeLisp opt2 from compiler revision `1faeb5067`, measured against Clang
23.1.3 on an AMD Ryzen 9 9950X pinned to logical CPU 14. The host used Linux
7.2.15-1-omarchy, glibc 2.44, Valgrind 3.25.1 and perf 7.2.11-1. Cycle
counts are the median of five whole-process user-mode samples.
Ratios are TypeLisp divided by Clang. The published CI Ir pins are
measured separately with Ubuntu Clang 18.

| Workload group | C reference | Pairs | Ir geomean | Cycle geomean |
| --- | --- | ---: | ---: | ---: |
| Realistic kernels | Scalar Clang `-O2` | 18 | 1.107× | 1.100× |
| Realistic kernels | Auto-vectorized Clang `-O2` | 18 | 1.114× | 1.103× |
| AVX2 SPMD | Clang `-O2 -mavx2 -mno-avx512f` | 8 | 1.059× | 0.989× |

## Realistic kernels and FP probes

The per-pair rows below use Clang `-O2 -fno-vectorize -fno-slp-vectorize`.

| Benchmark | Ir ratio | TypeLisp cycles | Clang cycles | Cycle ratio |
| --- | ---: | ---: | ---: | ---: |
| `cfg_domloops` | 1.256× | 168,854,679 | 157,314,842 | 1.073× |
| `gvn_table` | 1.076× | 210,098,228 | 159,491,844 | 1.317× |
| `intern_table` | 1.192× | 148,274,039 | 124,549,956 | 1.190× |
| `lex_source` | 0.846× | 191,417,049 | 185,013,988 | 1.035× |
| `liveness_scan` | 0.720× | 130,451,305 | 112,139,627 | 1.163× |
| `peephole_lines` | 0.854× | 109,535,598 | 100,175,377 | 1.093× |
| `read_sexpr` | 1.102× | 255,607,283 | 234,995,592 | 1.088× |
| `callgraph_scc` | 1.271× | 160,553,685 | 128,672,997 | 1.248× |
| `ssa_construct` | 1.371× | 189,112,642 | 169,993,388 | 1.112× |
| `sccp_lattice` | 1.308× | 202,146,146 | 167,816,173 | 1.205× |
| `regalloc_greedy` | 1.336× | 208,552,196 | 178,155,302 | 1.171× |
| `asm_render` | 1.067× | 300,139,000 | 271,222,997 | 1.107× |
| `opt_bytecode_vm` | 1.045× | 151,971,143 | 151,363,878 | 1.004× |
| `opt_crc32` | 0.806× | 484,590,954 | 484,732,755 | 1.000× |
| `opt_quicksort` | 1.015× | 571,781,648 | 550,727,791 | 1.038× |
| `graph_dijkstra` | 1.323× | 346,635,812 | 342,790,299 | 1.011× |
| `phys_nbody` | 1.331× | 168,051,585 | 161,252,183 | 1.042× |
| `route_http` | 1.392× | 90,039,500 | 92,556,175 | 0.973× |

### FP probes

| Benchmark | Ir ratio | TypeLisp cycles | Clang cycles | Cycle ratio |
| --- | ---: | ---: | ---: | ---: |
| `fp_taylor_exp` | 1.021× | 77,147,327 | 76,739,683 | 1.005× |
| `fp_mixed_recurrence` | 1.083× | 134,089,206 | 133,130,992 | 1.007× |

## Eight AVX2 SPMD pairs

| Benchmark | Ir ratio | TypeLisp cycles | Clang cycles | Cycle ratio |
| --- | ---: | ---: | ---: | ---: |
| `spmd_map` | 0.905× | 674,504,059 | 619,379,997 | 1.089× |
| `spmd_zip` | 0.979× | 999,755,525 | 806,088,815 | 1.240× |
| `spmd_reduce` | 1.200× | 173,794,382 | 319,079,526 | 0.545× |
| `spmd_scan` | 1.004× | 935,643,988 | 1,238,322,357 | 0.756× |
| `spmd_shuffle` | 1.186× | 343,446,331 | 380,023,470 | 0.904× |
| `spmd_short_tail` | 0.982× | 315,517,618 | 281,285,529 | 1.122× |
| `spmd_mask` | 1.097× | 359,834,134 | 313,380,939 | 1.148× |
| `spmd_foreach_2d` | 1.160× | 282,081,188 | 198,663,382 | 1.420× |

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
