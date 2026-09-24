# Reuse invariant calls at their first execution point

Inlining can bury a repeated, write-free call inside a loop before LICM can
recognize the call as a reusable computation. `opt_runtime_string_eq` repeats
the same string comparisons on every iteration; `opt_string_scan` similarly
repeats an unchanged scan.

Before opt2 inlining, cache one costly invariant call per caller. A dedicated
loop preheader initializes a flag and scalar cache. At the original call site,
the false flag executes the original call and records its result; later visits
read the cache. The call is never speculatively executed. Zero-trip loops,
conditional calls, earlier traps and a trapping first call retain their order.
Nested loops reset their cache on each entry through the preheader.

Admission requires all of the following:

- A natural loop with a dedicated preheader ending in a jump.
- No memory-writing, unknown or CPU-probing instruction in the loop. Direct
  calls require an existing write-free summary; indirect calls refuse caching.
- Every variable argument has exactly one definition, outside the loop.
- A supported integer/bool result and a callee with at least 16 IR instructions.
- At most 64 blocks in the caller. Only one site is rewritten per caller.

Splitting the call block repairs successor phi predecessor labels. Ordinary
SSA construction supplies the cache and flag phis. Both inline entry points
perform the rewrite before building their call graph and census; the original
call's destination and source-span key remain intact.

## Measurements

Base: main `c791ce29`. Linux x86-64, Ryzen 9 9950X, Clang 22.1.8, TypeLisp opt2
and Clang `-O2`. Both compiler binaries were built by the same seed. Of 44
benchmarks, **42 emit byte-identical assembly**; only the two below change.

Cachegrind executed instructions, with cache/branch simulation disabled and
`--vex-guest-chase=no`, using the committed benchmark arguments:

| Benchmark | Before | After | Change | Clang auto |
| --- | ---: | ---: | ---: | ---: |
| opt_runtime_string_eq | 61,402,096 | 1,402,401 | -97.72% | 209,064 |
| opt_string_scan | 21,316,161 | 211,769 | -99.01% | 25,018,995 |

Text size grows from 8,171 to 8,189 bytes for string equality and from 7,063 to
7,077 bytes for string scanning. No existing instruction baseline row covers
these two cases; all covered benchmarks retain identical assembly.

The default workloads finish in well under a millisecond after this change,
so process startup and shared-host scheduling obscure wall-time ratios. The
initial five-round run measured about 2.4 to 0.27 ms for string equality and
1.16 to 0.24 ms for scanning, but these are not precise runtime estimates.

For a longer comparison, multiply only the repetition argument by 100:
20,000,000 equality rounds and 3,500,000 scan rounds. Keep the same input text.
Fifteen rounds pinned to CPU 8 rotate execution order and check exit status,
stdout and stderr on every run. Median wall times:

| Benchmark | Before ms | After ms | Clang auto ms |
| --- | ---: | ---: | ---: |
| opt_runtime_string_eq | 452.777 | 11.159 | 1.791 |
| opt_string_scan | 100.767 | 2.397 | 99.033 |

Both improve by approximately 97.5%, but equality still takes **6.23 times**
Clang's runtime on the longer workload. The remaining cached loop pays for
its flag branch and spilled induction/accumulation state. LLVM parity is not
established by this change.

Compiler cost is measured separately: compiling `src/compiler_liveness.tl` at
opt2 takes 32,641,846,098 executed instructions before and 32,667,057,494
after, **+0.0772%**. This is one compile workload, not a universal cost bound.

## Validation

- 141 optimizer tests, including direct admission/refusal checks, successor
  phi repair and valid SSA after cache insertion.
- All 689 Linux integration cases. New opt0/opt2 rows cover negative/zero
  trip counts, skipped and delayed calls, exact first-call division errors,
  earlier shift errors, memory writes, nested cache reset and varying arguments.
  The same rows are registered for Windows CI.
- All 44 paired opt2 benchmarks, five rounds each with output checks.
- Canonical bootstrap fixpoint and embedded-image provenance.
- Codegen and backend assembly target-parity gates; formatting, lint and
  implementation-language checks.

Artifacts in the development worktree's `target/exp/` include
`full-bench-v2/`, `loop-counts/`, `interleaved-long.tsv`,
`compile-base-c791.cg`, `compile-loop-call-v2.cg`, and the gate logs.
