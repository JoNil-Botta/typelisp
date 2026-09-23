# Signed division overflow guards

Variable signed division and remainder now detect `INT_MIN / -1` without
materializing either constant in temporary registers. `cmp $1, dividend` sets
OF exactly for the minimum signed value at the operand width; `jno` skips the
second comparison for every other dividend. Comparing the divisor with the
immediate `-1` completes the check. Neither operand changes. The zero check
still precedes overflow detection, and the source-located abort receives the
original normalized operands.

This uses CMP's subtraction flags, described in the
[AMD64 application programming manual](https://docs.amd.com/v/u/en-US/24592_3.24).
The argument applies independently to 8-, 16-, 32-, and 64-bit signed operands.
Unsigned division retains its zero check. Literal strength reduction is unchanged.

## Measurements

Base: `b01f4b326058586c3c01f8b779e064a702c10b1d`. Linux x86_64, AMD Ryzen 9
9950X, clang 22.1.8. Both compilers were built at optimization level 2 with the
same seed. The candidate reaches an opt2 bootstrap assembly fixpoint.

Cachegrind used `--cache-sim=no --branch-sim=no --vex-guest-chase=no`:

| Workload | Base instructions | Candidate instructions | Change |
| --- | ---: | ---: | ---: |
| `phys_nbody 64 440` | 850,637,437 | 779,742,867 | -8.334% |
| `regalloc_greedy` | 566,087,361 | 565,767,636 | -0.0565% |
| `sccp_lattice` | 557,467,872 | 557,467,776 | -96 |

The other ten main compiler-kernel rows and all five heavy TypeLisp rows are
exactly unchanged. Only the two changed main TypeLisp baselines are refreshed;
the C and CI-owned self-compile baselines are not replaced with local counts.

The physics force function shrinks from 3,101 to 2,797 bytes (-9.80%). Its
hottest division loses two scratch-register save/restore pairs. Whole executable
text falls from 16,394 to 16,090 bytes. Its seven-round median remains 56.60 ms
versus clang's 29.73 ms: there is no demonstrated wall-clock speedup on this
workload, and this change does not establish LLVM parity.

## Validation

- Every valid signed 8-bit operand pair satisfies the quotient/remainder
  reconstruction, remainder magnitude, and remainder sign rules at opt0/1/2.
- Boundary cases for all signed widths pass at opt0/1/2, including the minimum
  dividend divided by 1, 2, and -2 and its neighbor divided by -1.
- 48 dynamic overflow and zero-divisor cases preserve exit 135 and exact
  diagnostics across the four widths, both operations, and all three levels.
  The integration manifests retain opt0/opt2 trap cases on Linux and Windows.
- Backend guard-shape tests cover each signed width and the unsigned refusal;
  backend smoke and the consolidated codegen smoke suite pass.
- All 44 paired benchmarks retain exact output/status parity.
- All 693 Linux integration cases pass after merging upstream `e2206a24`,
  including the global-initializer and LICM element-bound correctness fixes.
- Linux/Windows IR parity (14 files, three levels) and assembly parity (six
  files, three levels, with the established allowlist) pass.

Reproduce the corpus checks with `scripts/bench.sh --correctness` and
`scripts/check-instruction-counts.sh --benchmarks-only --runs 1`, setting
`TYPELISP_BIN` and `TYPELISP_IR_CHECK_COMPILER` to the candidate. The local
instruction gate also reports C-baseline differences from the hosted clang
version; those are independent of this change and are not ratcheted here.

## Upstream refresh

After the `e2206a24` merge, all twelve compiler-kernel TypeLisp instruction
counts were remeasured. `regalloc_greedy` changes from upstream
574,276,989 to 573,957,264 (-319,725); `sccp_lattice` retains its -96
instruction improvement. The other ten match upstream exactly. Only the
affected TypeLisp baseline rows were updated. Earlier timing and physics
measurements above retain their explicitly named base.
