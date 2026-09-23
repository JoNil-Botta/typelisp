# Independent partial sums in unrolled integer reductions

The sixteen-copy unroller kept every addition of a reduction on one dependency
chain. The x86 backend folded the loads into those adds, producing sixteen
serial memory-source additions even though the loads were independent. Split a
private `i64` or `u64` sum into four chains inside each sixteen-copy group, then
join the partials with three additions before the back edge. The first partial
starts with the incoming sum; the other three start at zero. The original loop
entry, short remainder groups, bounds checks, and exit phis remain intact.

Admission requires one non-counter phi, a body of at most twelve instructions,
and a direct addition update (optionally followed by one private copy). Neither
the phi nor its update may be used elsewhere in the body. Unknown instruction
forms refuse the rewrite. This excludes addresses, stores, conditions and other
recurrences that could observe an intermediate sum. Integer addition wraps and
is associative; floating-point addition is not admitted. This is scalar
instruction-level parallelism, with no new SIMD requirement.

## Measurements

Base: `b01f4b326058586c3c01f8b779e064a702c10b1d`. Both compiler binaries built at
opt 2 on the same AMD Ryzen 9 9950X Linux host; Clang 22.1.8, GNU binutils 2.47,
Valgrind 3.25.1. The host is shared with other workers. Nine rounds rotated the
order of the four executables, after one warmup each, verifying exact exit code,
stdout and stderr on every run. These are elapsed-time medians, including process
startup, and not claims about other CPUs.

| Benchmark | Base TypeLisp | Candidate | Clang `-O2` | Clang scalar `-O2` |
| --- | ---: | ---: | ---: | ---: |
| array_sum | 225.636 ms | 88.029 ms | 114.924 ms | 227.708 ms |
| spmd_reduce (scalar backend) | 228.142 ms | 87.661 ms | 226.648 ms | 457.963 ms |

That is 2.56x and 2.60x faster than base, respectively. `scripts/bench.sh --runs 5`
also passed all 44 paired benchmarks; its candidate medians were 87.505 ms and
86.135 ms for these two cases. The ordinary array loop remains scalar and is
faster than Clang's auto-vectorized binary on this host. Default `spmd_reduce`
also uses the scalar backend; this does not measure the explicit AVX2 backend.

There is a deliberate instruction-count tradeoff: three additional joining adds
per sixteen inputs. Executable text grows by 16 bytes in each of these binaries
(6,922 -> 6,938 and 7,254 -> 7,270 bytes).

| Deterministic TypeLisp instruction count | Base | Candidate | Delta |
| --- | ---: | ---: | ---: |
| array_sum | 1,426,253,747 | 1,651,291,247 | +15.778% |
| spmd_reduce | 1,473,975,345 | 1,703,476,110 | +15.570% |
| Other 21 main baseline cases | | | unchanged |
| All 5 heavy baseline cases | | | unchanged |

Only the two affected TypeLisp baseline rows are updated. C rows and the CI-owned
absolute self-compile row are untouched. The local count gate reports C-row drift
with this host's Clang version, as it does on base. Assembly changes in eleven
of the 44 programs, including shared helper reductions whose full groups do not
execute in the counted workloads.

Compiling `src/compiler_liveness.tl` at opt 2 executes 32,554,629,976
instructions versus base's 32,495,594,520 (+0.182%). This compiler-workload cost is
measured separately from generated-code speed; the extra recognition work is not
free. Neither the self-compile baseline nor any compiler-speed parity claim is
changed.

## Validation

- 140 existing optimizer inline tests plus the new admission test pass; optimizer
  smoke exits 42.
- The admission test covers direct and copied signed sums, unsigned sums, short
  groups, a doubled recurrence, non-additive and floating updates, and uses of
  the phi/update in addresses, owner metadata, and unknown instructions.
- The runtime fixture checks every trip count from 0 through 129, nonzero seeds,
  signed and unsigned wraparound, and both operand orders at opt 0/1/2. Its opt 2
  IR contains independent partial sums. An out-of-bounds trip preserves the
  exact source diagnostic and exit 134.
- All 665 Linux integration cases pass, including four new rows. Matching
  Windows manifest rows are added for CI.
- Linux/Windows target IR parity passes for 14 sources across three opt levels;
  backend assembly parity passes for six sources across three levels with the
  existing allowlist.
- An opt 2 bootstrap reaches identical stage2/stage3 assembly.
- Changed TypeLisp files pass formatting and lint; implementation-language gate
  and `git diff --check` pass.

Scratch artifacts: `target/exp/sum-chains/` in this worktree (`paired-times.tsv`,
`full-bench/`, `counts/`, `counts-extra/`, `counts-heavy/`, `valid-2.ir`, and the
integration/parity logs). LLVM parity remains unestablished across the corpus;
this closes the measured array-sum gap rather than establishing general parity.

## Upstream refresh

Merged upstream `e2206a24`, rebuilt the opt 2 compiler, and passed all 674
Linux integration cases, including the new LICM element-bound and global-
initializer regressions. Earlier performance measurements retain their
explicitly named base.
