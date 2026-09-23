# Preserve read-only call results across branch joins

Pure direct-call CSE previously discarded all available results at a block with
more than one predecessor. It now retains a result only when every predecessor
has already been visited and every exit table contains that exact result ID.
The existing single-definition rule makes this the same completed call on every
path. A write or unknown call clears its path's table. A missing path, a later
predecessor or loop back edge, or two distinct branch-local result IDs refuses
the reuse. No call is moved or speculated, and no phi is synthesized.

This also applies between checked-inlining generations. A previously inlined
pure call leaves a result definition that can replace a later surviving call
after a write-free diamond.

## Measurements

Base: `e2206a247049d413a2ec6e0001bad467e60fac69`. Linux x86-64, Ryzen 9
9950X, Clang 22.1.8, both TypeLisp compilers built at opt 2. The added paired
`pure_call_join` benchmark computes a runtime-dependent integer mixing loop,
a different mix in each branch, and the original mix again after the join.
All arithmetic in the C baseline uses `uint64_t` to preserve wrapping.

Fifteen interleaved rounds, rotated base/candidate/Clang order, pinned to CPU 8:

| Implementation | Median milliseconds |
| --- | ---: |
| Upstream TypeLisp | 33.526724 |
| Candidate TypeLisp | 22.832059 |
| Clang `-O2` | 32.967258 |

The candidate is 31.9% faster than upstream on this case and 30.7% faster than
Clang. The separate standard harness also verifies output/status parity with
both Clang auto-vectorization and scalar modes. These are same-host results on
a shared machine, not evidence of general LLVM parity.

Cachegrind (`--cache-sim=no --branch-sim=no --vex-guest-chase=no`) counts
232,501,100 instructions before and 154,501,100 after: 78,000,000 fewer
(-33.55%). Executable text shrinks from 9,126 to 9,115 bytes. All 44 pre-existing
benchmark assemblies are byte-identical; none of their baselines are changed.

Compiling the same upstream `src/compiler_liveness.tl` at opt 2 costs
32,637,875,522 instructions before and 32,642,563,628 after (+0.0144%), with
byte-identical emitted assembly. This recognition cost is reported separately
from generated-program performance. The CI-owned self-compile baseline remains
unchanged.

## Validation

The optimizer tests cover the admitted diamond and refusals for a store on one
arm, an impure call on one arm, re-execution after a store with a distinct result,
an unvisited predecessor, a loop back edge, a call available on only one path,
and independent calls on both paths. The existing CSE test now checks that its
join reuses the dominating result. Runtime integration covers direct and called
global mutation, a write-free branch, and a conditional first call at opt 0/1/2.

Validation completed with the rebuilt compiler:

- 141 optimizer inline tests and all 673 Linux integration cases pass.
- All 45 paired benchmarks pass exact output/status checks over three timed
  rounds at opt 2; the new benchmark is registered in the Linux CI corpus.
- Canonical bootstrap passes with identical stage2/stage3 assembly and embedded
  provenance output.
- Linux/Windows IR parity passes for 14 sources at three opt levels; assembly
  parity passes for six sources at three levels with the existing allowlist.
- Changed TypeLisp files pass formatting and lint; the implementation-language
  gate and diff whitespace checks pass. Windows execution remains for CI.

Artifacts are under `target/exp/call-joins/`: benchmark reports and interleaved
samples, Cachegrind outputs, the 44-case assembly comparison, unit/integration
logs, target parity, and bootstrap logs.
