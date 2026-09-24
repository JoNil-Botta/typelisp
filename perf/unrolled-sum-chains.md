# Independent partial sums in integer reductions

The unroller kept all sixteen additions of a private integer reduction on one
dependency chain. The backend folded loads into these serial additions, leaving
independent loads waiting on the accumulator. This change carries four partial
sums across a thirty-two-copy group and joins them once, on loop exit.

The original accumulator supplies the first partial's initial value. Three new
phis start at zero and carry their own final partial on the group backedge. A
separate exit block joins the four values with three additions. The cascade and
scalar remainder receive the complete sum from this block. Skipping the group
still carries the original seed directly into the remainder. The wider group
amortizes the setup and exit join while reducing branch/counter overhead.

Admission requires one non-counter phi, a body of at most twelve instructions,
and a direct `i64` or `u64` addition update (optionally followed by one private
copy). Neither the phi nor its update may be used elsewhere in the body. Unknown
instruction forms refuse the rewrite. This excludes addresses, stores,
conditions and other recurrences that observe intermediate sums. Integer
addition wraps and is associative; floating-point and narrow-width addition are
not admitted. Load order remains unchanged. Other unroll classes and the
four-copy cascade keep their existing factors.

## Measurements

Base: current main `f716205a1`. Both compilers were built at opt 2 by the same
seed on AMD Ryzen 9 9950X, Linux; Clang 22.1.8, GNU binutils 2.47, Valgrind 3.25.1.
Fifteen interleaved rounds rotated executable order, pinned to CPU 14, after a
warmup. Every execution checked exit status, stdout and stderr against the
others. These are elapsed-time medians including process startup, on a shared
host; they are not predictions for other CPUs.

| Benchmark | Base TypeLisp | Candidate | Clang `-O2` |
| --- | ---: | ---: | ---: |
| array_sum | 229.481 ms | 86.296 ms | 117.374 ms |
| spmd_reduce, scalar backend | 231.385 ms | 66.781 ms | 230.138 ms |
| asm_render | 64.727 ms | 64.792 ms | 55.357 ms |
| opt_array_sum | 1.280 ms | 1.256 ms | 1.441 ms |

The two large reductions improve 62.4% and 71.1%. Array sum is 26.5% faster than
Clang's auto-vectorized binary on this host. The small `opt_array_sum` workload
is sensitive to startup overhead. These four are the only changed benchmark
assemblies; the other **41 of 45** are byte-identical to main. A separate
five-round run of all 45 paired benchmarks verifies their observable outputs.

| Deterministic TypeLisp instructions | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| array_sum | 1,426,253,747 | 1,313,771,003 | -7.89% |
| spmd_reduce, scalar | 1,473,975,345 | 1,364,174,979 | -7.45% |
| opt_array_sum | 1,493,371 | 1,482,139 | -0.75% |
| asm_render | 748,804,912 | 748,804,912 | unchanged |

The two affected required TypeLisp rows are lowered. Other required rows emit
identical assembly or have the unchanged renderer count above. C rows and the
CI-owned self-compile row are untouched. The count script still reports the
host's existing Clang baseline drift, so this is not an all-rows gate-pass claim.
The optional scalar SPMD row is also lowered. Explicit AVX2 reduction is
unchanged at **1,006,026,764** instructions on both compilers; its older checked
baseline is not refreshed as part of this change.

Executable text grows by 160 bytes for array_sum (6,922 to 7,082) and 152 bytes
for spmd_reduce (7,254 to 7,406). This code-size cost buys fewer executed
instructions and shorter dependency chains. No padding instructions are added.

Compiling identical `src/compiler_liveness.tl` at opt 2 costs **32,557,733,519 →
32,600,612,485** instructions, **+0.132%**. This is measured compiler work,
separate from the generated programs' runtime, and is not compiler-speed parity.

## Validation

- All 143 optimizer inline tests pass. Admission checks include copied and
  direct signed sums, unsigned sums, short groups, doubled/non-add recurrences,
  observed updates, unknown instructions, floating-point and narrow types,
  multiple carried sums, and bodies above the size cap.
- A whole-function IR test verifies the input and output, follows all 32 updates
  through four distinct phi-backed chains, checks every final partial against
  its backedge, checks the three balanced exit additions, and requires the
  cascade's sum phi to receive their final result.
- Runtime cases cover every trip count from 0 through 129, nonzero seeds,
  signed/unsigned wraparound, both operand orders, and exact bounds-error
  behavior at opt 0/1/2. Existing scheduling tests check repeated application,
  verification rollback and unchanged non-reduction unroll classes.
- Opt 2 bootstrap reaches byte-identical stage2/stage3 assembly and embedded
  provenance. Codegen target parity passes for 14 fixtures at three levels;
  backend assembly target parity passes for six fixtures at three levels.
- All 698 Linux integration cases pass, including optimizer smoke and the new
  runtime cases. Formatting, full lint, implementation-language policy and
  `git diff --check` pass. Matching Windows cases await hosted CI.

Reproduction:

```sh
TYPELISP_BIN=/path/to/compiler scripts/bench.sh --runs 5 --cpu 14 --output target/exp/reduction-bench
TYPELISP_BIN=/path/to/compiler scripts/measure-instruction-counts.sh --benchmarks-only --runs 1 --cases array_sum,spmd_reduce,asm_render,opt_array_sum --output target/exp/reduction-counts
TYPELISP_BIN=/path/to/compiler scripts/measure-spmd-mode-instruction-counts.sh --runs 1 --cases spmd_reduce --modes scalar,avx2 --output target/exp/reduction-spmd-counts
```

Detailed local results are under `target/exp/sum-chains/persistent/`: the
interleaved sample TSV, paired harness results, assembly comparisons, counts,
compiler-cost logs and validation logs. General LLVM parity remains unestablished.
