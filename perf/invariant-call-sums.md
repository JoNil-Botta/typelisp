# Fold guarded invariant-call sums

After the first-call guard has proved that a counted loop executes, an invariant
call followed only by `sum += result; counter += 1` does not need an accumulation
loop. Its final sum is `old_sum + (bound - counter) * result`, with the same
wrapping arithmetic as the original i64/u64 additions. The counter reaches bound
without wrapping: the original guard requires `counter < bound`, and the stride
is exactly one. The low 64 bits of the trip count also handle a signed interval
whose mathematical length exceeds signed max.

The first call stays behind the original guard and at its original position.
Zero and negative trip counts still skip it, and an executing call still traps
before any accumulation. The rewrite preserves the final counter, sum temporary,
step literal and false comparison value as well as the accumulator. SSA repairs
uses on the zero-trip and completed-loop exits.

The existing purity, argument-invariance, predecessor and literal-prefix gates
remain required. The additional matcher admits only a two-instruction `<` guard
and the exact scalar sum/unit-stride suffix. It rejects floating point, narrow
integers, differing integer types, other strides, varying bounds and aliased
state/temporary names. Every other admitted call keeps the guarded reuse path.

This change is stacked on the guarded-call rewrite, measured against parent
`a8bbd563f`, with upstream through `7916cfa5` in both compilers. The seed is the
same opt2 current-main compiler.

| Case | Parent Ir | New Ir | Clang auto Ir |
|---|---:|---:|---:|
| opt_runtime_string_eq | 802,415 | 2,414 | 9,914 |
| opt_string_scan | 141,769 | 1,768 | 24,820,406 |

New counts are stable across three runs. All 46 paired benchmark outputs match;
only the two assemblies above change relative to the original guarded-call
implementation (the upstream small-multiply benchmark is checked separately).
Both text sections shrink by 13 bytes: 8,854 to 8,841 and 8,021 to 8,008.

Fifteen rotated, interleaved CPU-14 samples on Ryzen 9 9950X give these medians,
with one warmup. Arguments use 20 million equality rounds and 3.5 million scan
rounds; outputs and exit statuses match in every sample.

| Case | Parent ms | New ms | Clang auto ms |
|---|---:|---:|---:|
| string equality | 5.074 | 1.207 | 1.321 |
| string scan | 1.970 | 1.245 | 96.800 |

The new equality/scan loops perform constant work in the round count. Their
remaining runtime is close to process startup, so small timing differences
should not be generalized. This closes these accumulation-loop gaps; it does
not establish general LLVM parity.

Compiling the same `src/compiler_liveness.tl` at opt2 executes exactly
32,573,735,849 instructions with either compiler and produces identical assembly.
That probe sees no compiler-cost increase; it is not a whole-compiler cost bound.
No existing instruction baseline is raised.

IR tests cover signed/unsigned admission, literal/direct unit strides, refusal
cases, verified original and rewritten SSA, one multiplication and removal of
the backedge. Runtime checks enumerate 129 loop bounds, wrapping sums, signed
minimum/maximum counters, an unsigned maximum counter, live exit state and
zero-trip calls that would divide by zero. Positive-trip division traps retain
their diagnostic location. The existing paired cases remain in the benchmark
and optimization-opt2 suites.

Reproduce with `scripts/bench.sh --runs 5 --cpu 14` and
`scripts/measure-instruction-counts.sh --benchmarks-only --cases
opt_runtime_string_eq,opt_string_scan --runs 3`, selecting each compiler through
`TYPELISP_BIN`. Detailed artifacts are under `target/exp/call-sum-current/`.
