# Loop-call caching through literal temporaries

A source call such as `(read-sum values 7)` gets a loop-local temporary for `7`
before SSA. The initial invariant-call pass rejects every name defined inside
the loop, so the literal prevented it from reusing an otherwise invariant,
read-only result. A single definition that moves a scalar literal into a name
always gives that name the same value when its defining instruction executes.

The loop's definition scan now excludes such names from the varying set. The
assignment stays at its original position, and the lazy cache still calls the
helper only at its first actual execution. No instruction or call is speculated.
Whole-function definition counts exclude redefined names and parameters that
are assigned again. Global reads, variable copies and allocated literals remain
conservative refusals. The collector still makes one pass over each candidate
loop and uses its existing map; it adds no whole-function storage.

This is a follow-up to #8024, based on `af984b1f8`, with both compilers built by
the same `f716205a` opt2 seed. All **44 existing benchmark assemblies remain
byte-identical**. The new paired benchmark uses runtime input and folds the
helper result with the varying loop index, retaining an observable recurrence.

## Measurements

AMD Ryzen 9 9950X, Linux, Clang 22.1.8, Valgrind 3.25.1. Fifteen interleaved
rounds rotate executable order on CPU 14, check exact exit/stdout/stderr, and
use one warmup. The host is shared. For arguments `13 20000000`:

| | Parent | Candidate | Clang auto `-O2` |
| --- | ---: | ---: | ---: |
| Median elapsed time | 130.985 ms | 17.048 ms | 13.125 ms |

Runtime improves **87.0%**, but remains **30% slower than Clang** on this longer
run. Instruction-count parity does not imply runtime parity.

At the default one million rounds, executed instructions are:

| Parent TypeLisp | Candidate TypeLisp | Clang auto | Clang scalar |
| ---: | ---: | ---: | ---: |
| 110,001,406 | 9,001,513 | 9,005,198 | 100,005,191 |

The new required TypeLisp/scalar-C baseline rows match exactly. No existing row
is changed. The benchmark and both language implementations are checked in.

Compiling identical `compiler_liveness.tl` source at opt2 takes
**32,664,632,065 → 32,664,560,014** instructions (-0.00022%), effectively
unchanged. This compiler-work metric is separate from generated-code speed.

## Validation

- All 141 optimizer tests pass. The call-cache fixture now admits a loop-local
  literal and refuses two definitions, a variable copy and a global read.
- The fixture also pins the existing cache protocol: false executes the call,
  true takes the reuse edge, the preheader clears the flag, the execute block
  stores the returned value before setting the flag, and the resume block
  reads the stored result. SSA and successor-phi verification remain checked.
- New runtime cases cover delayed and skipped calls, zero trips, a literal-zero
  denominator behind never-reached calls, mutation through a callee and a
  global-writing helper. Opt0 and opt2 produce the same reference checksum.
- All 45 paired opt2 benchmarks pass three interleaved rounds, and the new
  instruction-count gate matches exactly. Both codegen target-parity suites
  pass. Canonical bootstrap reaches identical stage2/stage3 assembly and
  embedded provenance; all 691 Linux integration cases, full lint, formatting
  and implementation-language policy pass. Windows execution awaits CI.

Reproduce with `scripts/bench.sh --cases loop_call_literal --runs 5 --cpu 14`
and `scripts/check-instruction-counts.sh --benchmarks-only --benchmarks
loop_call_literal --runs 1`, selecting the compiler with `TYPELISP_BIN`.
Local detailed artifacts live under `target/exp/literal-call/` in this checkout.
General LLVM parity remains unestablished.
