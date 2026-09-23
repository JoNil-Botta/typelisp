# Shift multiplication by wide constant globals

A literal global such as `17179869184` (2^34) previously stayed a global read
at every scalar operand position. The general restriction is profitable: a wide
literal can require a `movabs` at every use, replacing a value already held in a
register. Multiplication by a positive power of two is an exception: its exponent
is a small immediate, so the entire multiply can become a single shift.

The existing program-wide store/address-escape scan still qualifies constants.
The table now retains positive powers of two as well as signed-imm32 constants.
Ordinary operands still reject wide literals. Only an `i64`/`u64` multiplication
with a global operand consumes a wide power as a shift count in [31, 62]. Both
operand orders work. Negative constants, arbitrary wide constants, mutable or
address-taken globals, and runtime initializers keep their existing treatment.
The shift computes the same low 64 bits as wrapping multiplication, and its
literal count cannot trigger a checked-shift abort.

## Measurements

Base `b01f4b32`, opt 2 compilers, AMD Ryzen 9 9950X, Linux, Clang 22.1.8,
Valgrind 3.25.1. The host is shared with other workers. The paired benchmark's
multiply/xor recurrence keeps its input live and mixes high bits back into the
low bits; it does not collapse to repeated multiplication of zero.

Nine interleaved rounds with one warmup per executable:

| `mul_wide_power` | Median |
| --- | ---: |
| Base TypeLisp | 72.644 ms |
| Candidate TypeLisp | 37.965 ms |
| Clang `-O2` | 37.869 ms |
| Clang scalar `-O2` | 37.928 ms |

The candidate is 1.91x faster than base and within 0.3% of Clang in this run.
Candidate and base were measured in separate harness invocations, each with its
own interleaved Clang controls. Candidate executable text shrinks 6,177 -> 6,174
bytes, and data shrinks 48 -> 40 bytes. The final compiler emits identical
assembly for this workload to the timed candidate.

`phys_nbody` also loses its global multiply in both versions of `nb-forces`,
replacing it with `shlq $34`. Its candidate median is 57.917 ms versus Clang's
30.633 ms; no wall-time improvement over base is established for that workload.
This change does not close the physics gap or establish general LLVM parity.

All twelve compiler-kernel TypeLisp instruction-count baseline rows remain
exactly unchanged. No baselines are updated. Local C-row count differences come
from the host Clang version and also occur on base. Compiling
`src/compiler_liveness.tl` costs 32,594,392,745 instructions versus base's
32,495,594,520 (+0.304%); recognition and the extra retained table entries have a
small compiler-workload cost.

## Validation

- All 45 paired benchmarks agree with C, including the new recurrence; the final
  candidate also runs the full corpus at opt 2 with three timing rounds.
- 141 optimizer inline tests pass; optimizer smoke exits 42. The new test covers
  every exponent 31–62, signed/unsigned operands and both orders, plus refusal
  of non-powers, zero, small powers and negative constants. It also preserves
  ordinary wide-global operands and literal products synthesized by unrolling.
- The runtime fixture passes at opt 0/1/2 with overflowing positive/negative
  values, unsigned inputs, direct mutation, writes through a borrowed global,
  runtime initialization, and non-multiply uses of the same wide constants.
- All 664 Linux integration cases pass, including three new rows. Corresponding
  Windows rows are included for CI.
- Opt 2 bootstrap reaches identical stage2/stage3 assembly. Linux/Windows target
  IR parity (14 sources x three levels) and backend assembly parity (six sources
  x three levels, existing allowlist) pass.
- Changed TypeLisp files pass format/lint; language policy and diff checks pass.

Artifacts are in `target/exp/wide-mul/`: `base-bench/`, `bench2/`,
`full-bench-final/`, `counts-final/`, `liveness-module.cg`, and final bootstrap,
integration and parity logs. `--correctness` is also run, but that harness mode
uses the compiler's default optimization level; opt 2 evidence comes from the
separate timing run.

## Upstream refresh

Merged upstream `e2206a24`, including the global-initializer and LICM element-
bound correctness fixes. Rebuilt the opt 2 compiler and passed all 673 Linux
integration cases. The measurements above retain their explicitly named base;
they are not reinterpreted as measurements of the combined upstream changes.
