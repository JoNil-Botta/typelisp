# Scalar replacement of private String descriptors

A String has a fixed 16-byte descriptor (data pointer and length) and a
separately allocated byte buffer. The aggregate word-splitting pass previously
excluded String, leaving some private descriptor allocations and stores in the
output even when only their words were needed.

The split pass now recognizes exactly `tl_alloc(16): String`. Its existing
complete-use, definition, pointer-closure, access-type, ownership and escape
checks still decide whether to split it. This does not broaden general stack
promotion, remove the byte buffer, or admit foreign allocation functions.
Calls receiving the descriptor, stores of its address, ownership edges,
subword accesses, dynamic offsets and incompatible copies remain refusals.

The inline regression reuses the branch, whole-copy and refusal fixtures with
String descriptors. It checks the resulting constant length through the full
optimizer, ownership-edge refusal, and wrong allocator/size rejection. The
existing native String cases and paired benchmarks cover generated execution.

## Measurements

Linux x86-64, Ryzen 9 9950X, Clang 22.1.8 `-O2`, against upstream `ea7fd6bdc`.
All measurements use opt2 TypeLisp binaries and verify stdout, stderr and exit
status. Cachegrind disables VEX guest chasing; three runs agree exactly.

| Benchmark | Before Ir | After Ir | Change | Text bytes before/after |
| --- | ---: | ---: | ---: | ---: |
| opt_allocation_heavy | 4,599,562 | 4,149,562 | -9.8% | 8,844 / 8,760 |
| opt_runtime_string_int | 33,961,101 | 32,281,101 | -4.9% | 9,030 / 8,954 |
| opt_runtime_string_ops | 32,461,438 | 31,741,438 | -2.2% | 8,680 / 8,620 |

All 42 other benchmark assemblies are byte-identical. None of these three is
an existing instruction-main baseline row; no baseline is raised or changed.
All 45 paired benchmark cases pass three interleaved rounds.

Fifteen rotated CPU-14 timing samples, with ten times the default round count,
give these medians in milliseconds:

| Benchmark | Before | After | Clang auto |
| --- | ---: | ---: | ---: |
| opt_allocation_heavy (300,000 rounds) | 3.135 | 2.958 | 6.852 |
| opt_runtime_string_int (1,200,000 rounds) | 17.217 | 16.183 | 35.307 |
| opt_runtime_string_ops (600,000 rounds) | 55.971 | 54.969 | 27.114 |

The first two improve 5.6% and 6.0% in this run. String operations are noisier:
a preceding run against `823b0e6cd` measured 57.130 / 57.713 ms, so the 1.8%
improvement above should not be read as a robust runtime gain. That case still
runs about twice as slowly as Clang. The instruction and text reductions are
deterministic, and this change does not establish general LLVM parity.

A compiler-cost probe on `route_http` against `823b0e6cd` measures
4,849,097,550 / 4,849,275,844 Ir (+0.0037%), with identical output assembly.

Reproduce the deterministic comparison on each revision:

```sh
TYPELISP_BIN=/path/to/compiler scripts/measure-instruction-counts.sh \
  --benchmarks-only --runs 3 \
  --cases opt_allocation_heavy,opt_runtime_string_int,opt_runtime_string_ops \
  --output target/descriptor-ir
TYPELISP_BIN=/path/to/compiler scripts/bench.sh --runs 3 --cpu 14 \
  --output target/descriptor-bench
```

Investigation artifacts, assembly comparisons, raw timing samples and validation
logs are under ignored `target/exp/string-descriptors/` in the worktree.
