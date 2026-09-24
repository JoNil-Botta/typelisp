# Replaying scalar prefixes around invariant calls

A guarded invariant call can already run once and feed its cached result to
later iterations. A body beginning with scalar arithmetic still used the
flag-based cache: the arithmetic must execute on every trip, including the
first. Keep the original prefix and call together on first entry; subsequent
taken guard edges execute a separate prefix block and join the continuation.
The call stays below the original guard, so a zero-trip loop cannot execute it.

Only up to eight prefix instructions are replayed. Eligible operations are
i64/u64 moves and wrapping add, subtract, multiply, and bitwise operations on
variables or integer literals. Loads, global reads, shifts, division and
remainder are excluded. In particular, cloning trapping definitions before SSA
renaming would lose their unique diagnostic source-span identity. The existing
call-invariance, memory-write and address-taken checks still apply. Closed-form
sum folding continues to require an entirely literal prefix.

Measured on Linux / Ryzen 9 9950X against parent 0cb9a948d (#8029):

| measurement | parent | candidate |
|---|---:|---:|
| loop_call_literal executed instructions | 9,001,513 | 7,001,504 |
| executable text bytes | 8,571 | 8,507 |
| 20 million rounds, 15 rotated CPU-14 samples | 16.584 ms | 16.638 ms |
| compiling route_http, opt 2, executed instructions | 4,343,116,666 | 4,343,116,666 |

Clang -O2 takes 12.835 ms on the same long-run workload. Timing is essentially
unchanged; multiply latency still dominates. The improvement is fewer executed
instructions and smaller code, not established latency parity with LLVM.
The long-run checksum is 18083256300727556480 for every implementation.

All 46 benchmark assemblies were compared: only loop_call_literal changes.
Cachegrind disables cache/branch simulation and VEX guest chasing; the benchmark
count repeats exactly three times. Hosted C/self-compile baselines are unchanged.
The CRC32 baseline refresh records the already-lower current parent count.

Structural tests check six admitted arithmetic forms, rejected trapping/global
prefixes and the size cap, first-entry/replay edges, and SSA validity. Native
fixtures compare wrapping recurrences from negative through 129 trip counts,
including zero-trip calls that would divide by zero if speculated. Separate
first/later division, remainder and shift failures pin diagnostic locations at
all three optimization levels.

## Parallel-phi regression

Independent review found a backend bug exposed by the replay block: a lagged
loop counter could receive the incremented value when two leading phis were
processed sequentially by conservative liveness. The IR transformation itself
preserves the old counter. This branch includes the parallel-phi fix from
#8064 and depends on that fix landing before this optimization.

`replayed_loop_call_lagged.tl` retains the exact failing replay shape. Linux
and Windows manifest rows cover negative and zero trips plus 1, 2, 3, 10 and
65 trips at every optimization level. Before the fix, the three-trip opt-2
program prints `r=2 d=-3`; the expected result is `r=1 d=-3`.
