# Compact loop alignment after cold-stub outlining

Moving abort stubs out of the hot path changes machine-code addresses even
when a loop's instructions stay identical. In `spmd_shuffle`, COLD-1 moves a
15-instruction loop so its backedge straddles a 64-byte boundary. That layout
regresses runtime by about 15% on a Ryzen 9 9950X.

The final cold renderer now puts `.p2align 4` immediately before compact loop
headers. Admission requires 12–16 live instructions, including one conditional
backedge to the header, with no call, other branch, stack operation, directive
or intervening label. The scan is bounded to 32 records. Groups without an
actual outlined abort stub keep their existing output. Padding is inserted
after all textual optimizers, so it cannot change their matching or layout.
The backedge targets the label after the padding; padding executes only on
fallthrough entry. At most 15 bytes are added per admitted header.

The scope is deliberately conservative. Experiments aligning all self loops
or all machine-code backedges introduced regressions elsewhere. This change
protects compact loops affected by COLD-1; it is not a general layout policy.

## Runtime

Linux x86-64, Ryzen 9 9950X, Clang 22.1.8, TypeLisp opt2 and Clang `-O2`.
Each comparison uses 15 rounds pinned to CPU 8 with execution order rotated
between rounds. Numbers are medians; every run checks exit status, stdout and
stderr against the baseline. Both TypeLisp legs compile each benchmark
individually with the same build mode.

A four-way `spmd_shuffle` comparison separates the outlining regression from
the LLVM gap:

| Compiler | Median ms |
| --- | ---: |
| Upstream `cff2c02d` | 202.466 |
| Upstream plus COLD-1 (`621bf92f`) | 232.808 |
| COLD-1 plus this change | 202.023 |
| Clang auto-vectorization | 89.038 |

The fix restores upstream performance. TypeLisp remains 2.27 times slower
than Clang here; this is not LLVM parity.

A separate rotated run covers all seven benchmarks whose assembly changes:

| Benchmark | COLD-1 ms | Aligned ms | Change |
| --- | ---: | ---: | ---: |
| spmd_shuffle | 237.851 | 207.249 | -12.87% |
| route_http | 20.447 | 20.346 | -0.50% |
| asm_render | 63.709 | 63.626 | -0.13% |
| sccp_lattice | 43.036 | 43.058 | +0.05% |
| ssa_construct | 38.575 | 38.740 | +0.43% |
| opt_array_sum | 1.275 | 1.261 | -1.08% |
| opt_quicksort | 107.183 | 106.628 | -0.52% |

Only the shuffle result is a claimed runtime improvement. The other results
are approximately neutral, with the short array benchmark especially noisy.

## Code size and executed instructions

Of the 44 existing benchmarks, 37 emit byte-identical assembly. The other
seven differ only by alignment directives. Identical instructions with
different addresses can still change runtime; instruction count alone would
not detect the original regression.

| Benchmark | Headers | Text bytes before / after | Executed instructions before / after |
| --- | ---: | ---: | ---: |
| spmd_shuffle | 1 | 7,320 / 7,336 | 4,615,047,876 / 4,615,647,878 |
| route_http | 1 | 22,622 / 22,622 | 414,217,296 / 414,217,296 |
| asm_render | 1 | 30,940 / 30,956 | 748,804,912 / 748,804,932 |
| sccp_lattice | 1 | 36,803 / 36,803 | 557,467,872 / 557,467,872 |
| ssa_construct | 2 | 77,943 / 77,951 | 633,023,510 / 633,029,162 |
| opt_array_sum | 1 | 9,329 / 9,345 | 1,493,371 / 1,493,372 |
| opt_quicksort | 1 | 10,485 / 10,485 | 394,817,921 / 394,825,921 |

Counts use Cachegrind with cache and branch simulation disabled and
`--vex-guest-chase=no`. Three existing TypeLisp baseline rows are updated to
their measured values. C reference rows and the CI-owned self-compile baseline
are unchanged. All 12 default TypeLisp instruction-count checks pass. The
combined local gate reports unrelated C reference drift with this Clang build.

Compiling `src/compiler_liveness.tl` at opt2 takes 32,656,163,351 executed
instructions before and 32,677,192,341 after: **+0.0644%**. This measures
compiler overhead separately from generated-program runtime.

## Validation

- All 671 Linux integration cases, including backend smoke assertions for
  admitted sizes, refusals, cold-outlining scope and render idempotence.
- All 44 paired benchmarks at opt2, five runs each with output checks.
- Canonical bootstrap fixpoint and embedded-image provenance.
- Codegen target parity (14 fixtures, three targets) and backend assembly
  target parity (six fixtures, three targets).
- Assembly shape gates.
- Formatting, lint and implementation-language checks.

Reproduction artifacts are in `target/exp/compact-align/`: `interleaved.tsv`,
`shuffle-four-way.tsv`, `instruction-counts/summary.tsv`, `compile-base.cg`,
`compile-candidate.cg`, the paired benchmark build directories and gate logs.
