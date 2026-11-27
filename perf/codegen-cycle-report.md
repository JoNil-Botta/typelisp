# Codegen hardware cycle reference

TypeLisp opt2 from compiler revision `efa6389da`, measured against Clang
23.1.3 on an AMD Ryzen 9 9950X pinned to logical CPU 16. The host used Linux
7.2.15-1-omarchy, glibc 2.44, Valgrind 3.25.1 and perf 7.2.11-1. Cycle
counts are the median of five whole-process user-mode samples.
Ratios are TypeLisp divided by Clang. The published CI Ir pins are
measured separately with Ubuntu Clang 18. Baseline SSE2 is the default
x86-64 SPMD backend mode, so the default SPMD pairs need no `--backend-mode`.

| Workload group | C reference | Pairs | Ir geomean | Cycle geomean |
| --- | --- | ---: | ---: | ---: |
| Realistic kernels (core 12) | Scalar Clang `-O2` | 12 | 1.096× | 1.118× |
| Realistic kernels (core 12) | Auto-vectorized Clang `-O2` | 12 | 1.106× | 1.127× |
| Realistic kernels (pre-widening 18) | Scalar Clang `-O2` | 18 | 1.102× | 1.074× |
| Realistic kernels (pre-widening 18) | Auto-vectorized Clang `-O2` | 18 | 1.109× | 1.082× |
| Realistic kernels (widened 22) | Scalar Clang `-O2` | 22 | 1.207× | 1.127× |
| Realistic kernels (widened 22) | Auto-vectorized Clang `-O2` | 22 | 1.251× | 1.159× |
| FP probes | Scalar Clang `-O2` | 2 | 1.052× | 1.008× |
| Default SSE2 SPMD | Default Clang `-O2` | 8 | 0.929× | 0.848× |
| AVX2 SPMD | Clang `-O2 -mavx2 -mno-avx512f` | 8 | 1.058× | 0.988× |

The core 12 are the realistic kernels that predate the second widening step;
the pre-widening 18 add `opt_bytecode_vm`, `opt_crc32`, `opt_quicksort`,
`graph_dijkstra`, `phys_nbody` and `route_http`; the widened 22 add
`json_parse`, `radix_sort`, `fp_stencil_2d` and `btree_arena`.

## Realistic kernels and FP probes

The per-pair rows below use Clang `-O2 -fno-vectorize -fno-slp-vectorize`;
the `(auto)` columns compare the same TypeLisp binary against auto-vectorized
Clang `-O2`, and `Clang cycles` is the scalar baseline.

| Benchmark | Ir ratio | TypeLisp cycles | Clang cycles | Cycle ratio | Ir ratio (auto) | Cycle ratio (auto) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `cfg_domloops` | 1.255× | 167,290,708 | 157,553,305 | 1.062× | 1.264× | 1.055× |
| `gvn_table` | 1.076× | 208,757,072 | 160,598,278 | 1.300× | 1.076× | 1.280× |
| `intern_table` | 1.177× | 130,946,678 | 124,371,384 | 1.053× | 1.176× | 1.047× |
| `lex_source` | 0.839× | 182,490,733 | 185,075,986 | 0.986× | 0.839× | 0.987× |
| `liveness_scan` | 0.717× | 126,527,944 | 111,474,647 | 1.135× | 0.784× | 1.244× |
| `peephole_lines` | 0.854× | 107,446,846 | 100,291,656 | 1.071× | 0.854× | 1.069× |
| `read_sexpr` | 1.074× | 232,919,980 | 235,083,667 | 0.991× | 1.074× | 0.985× |
| `callgraph_scc` | 1.282× | 157,271,480 | 129,744,338 | 1.212× | 1.282× | 1.214× |
| `ssa_construct` | 1.363× | 190,610,776 | 168,745,168 | 1.130× | 1.381× | 1.135× |
| `sccp_lattice` | 1.283× | 204,715,925 | 168,781,728 | 1.213× | 1.283× | 1.199× |
| `regalloc_greedy` | 1.333× | 211,512,333 | 179,307,267 | 1.180× | 1.381× | 1.237× |
| `asm_render` | 1.152× | 310,009,545 | 275,136,557 | 1.127× | 1.109× | 1.122× |
| `opt_bytecode_vm` | 1.045× | 151,971,605 | 150,990,815 | 1.006× | 1.045× | 1.007× |
| `opt_crc32` | 0.805× | 484,554,192 | 484,737,433 | 1.000× | 0.805× | 1.000× |
| `opt_quicksort` | 1.015× | 579,436,229 | 573,655,514 | 1.010× | 1.015× | 1.028× |
| `graph_dijkstra` | 1.319× | 342,883,428 | 344,246,450 | 0.996× | 1.320× | 1.010× |
| `phys_nbody` | 1.191× | 167,151,064 | 161,143,697 | 1.037× | 1.191× | 1.035× |
| `route_http` | 1.428× | 83,837,471 | 92,429,282 | 0.907× | 1.428× | 0.907× |
| `json_parse` | 2.047× | 93,289,175 | 48,972,645 | 1.905× | 2.047× | 1.924× |
| `radix_sort` | 1.608× | 81,840,707 | 76,828,581 | 1.065× | 1.852× | 1.167× |
| `fp_stencil_2d` | 1.709× | 90,543,931 | 56,354,146 | 1.607× | 2.919× | 2.399× |
| `btree_arena` | 1.934× | 171,270,603 | 147,395,242 | 1.162× | 1.931× | 1.159× |

### FP probes

| Benchmark | Ir ratio | TypeLisp cycles | Clang cycles | Cycle ratio | Ir ratio (auto) | Cycle ratio (auto) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `fp_taylor_exp` | 1.021× | 77,326,227 | 76,919,902 | 1.005× | 1.021× | 1.007× |
| `fp_mixed_recurrence` | 1.083× | 134,115,938 | 132,742,698 | 1.010× | 1.083× | 1.012× |

## Eight default SSE2 SPMD pairs

The reference is default `clang -O2`; TypeLisp runs the default SSE2 backend
mode with no `--backend-mode` flag.

| Benchmark | Ir ratio | TypeLisp cycles | Clang cycles | Cycle ratio |
| --- | ---: | ---: | ---: | ---: |
| `spmd_map` | 0.979× | 726,781,621 | 762,382,342 | 0.953× |
| `spmd_zip` | 0.940× | 1,880,494,454 | 1,866,777,308 | 1.007× |
| `spmd_reduce` | 0.795× | 403,929,698 | 1,207,971,094 | 0.334× |
| `spmd_scan` | 0.788× | 1,245,599,815 | 1,236,543,417 | 1.007× |
| `spmd_shuffle` | 0.969× | 396,485,596 | 466,175,106 | 0.851× |
| `spmd_short_tail` | 1.007× | 568,406,571 | 633,053,114 | 0.898× |
| `spmd_mask` | 0.981× | 1,207,554,768 | 1,200,922,663 | 1.006× |
| `spmd_foreach_2d` | 1.003× | 375,972,878 | 350,274,530 | 1.073× |

## Eight AVX2 SPMD pairs

| Benchmark | Ir ratio | TypeLisp cycles | Clang cycles | Cycle ratio |
| --- | ---: | ---: | ---: | ---: |
| `spmd_map` | 0.905× | 673,539,173 | 622,156,780 | 1.083× |
| `spmd_zip` | 0.979× | 998,230,345 | 805,342,781 | 1.240× |
| `spmd_reduce` | 1.200× | 173,751,727 | 319,093,866 | 0.545× |
| `spmd_scan` | 1.004× | 935,422,428 | 1,235,204,550 | 0.757× |
| `spmd_shuffle` | 1.186× | 335,685,729 | 379,859,141 | 0.884× |
| `spmd_short_tail` | 0.976× | 316,189,218 | 281,359,232 | 1.124× |
| `spmd_mask` | 1.097× | 360,822,248 | 312,605,544 | 1.154× |
| `spmd_foreach_2d` | 1.159× | 284,328,827 | 199,425,429 | 1.426× |

## Object size at `-Os`

Geomeans of the per-pair TypeLisp over `clang -Os` ratios. Stripped is whole
file bytes, `.text` includes the runtime and toolchain sections, and user
`.text` drops them.

| Pair set | Stripped | `.text` | User `.text` |
| --- | ---: | ---: | ---: |
| Pre-widening 51 pairs | 0.830× | 4.246× | 2.216× |
| Widened 55 pairs | 0.850× | 4.275× | 2.279× |

## Reproduction

Build the compiler with `scripts/ci-verify.sh --gates bootstrap-compiler`.
Choose a logical CPU that is free of other benchmark work.

```sh
compiler=target/bootstrap-fixpoint/stage2
cpu=16
kernels=$(. scripts/lib-benchmark.sh && benchmark_ci_case_csv "$PWD" realistic-kernel)
taskset -c "$cpu" scripts/measure-instruction-counts.sh \
    --benchmarks-only --cases "$kernels,fp_taylor_exp,fp_mixed_recurrence" \
    --c-scalar --runs 1 --cycles "$compiler"
spmd=spmd_map,spmd_zip,spmd_reduce,spmd_scan
spmd="$spmd,spmd_shuffle,spmd_short_tail,spmd_mask,spmd_foreach_2d"
taskset -c "$cpu" scripts/measure-instruction-counts.sh \
    --benchmarks-only --cases "$spmd" --runs 1 --cycles "$compiler"
taskset -c "$cpu" scripts/measure-spmd-mode-instruction-counts.sh \
    --modes avx2 --runs 1 --cycles "$compiler"
scripts/benchmark-size-vs-clang.sh --opt-level s "$compiler"
scripts/run-diff-fuzzer.sh --seeds 500 --verify-ir --compiler "$compiler"
```
