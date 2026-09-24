# Reuse invariant calls through a duplicated loop guard

The lazy invariant-call cache tests its flag on every iteration. A two-block
while loop can instead keep the original first guard and call, then send its
backedge through a copy of the guard directly to the suffix after that call.
The completed result dominates that suffix without flag/result cache slots.
Zero-trip loops still skip the call, and the first call remains after the
original guard and literal assignments.

Admission requires the existing write-free/invariant-call proof, a unique
result definition, a single header predecessor for the call block, and exactly
the preheader and call block as predecessors of the original guard. The guard
must be a non-entry block with at most eight instructions and no phis; the call
block must jump back to it. Before the call, only singly defined scalar-literal
moves may occur. Explicit exit phis, conditional backedges, work before the call
and reused result destinations retain the general lazy cache. SSA construction
renames the duplicated guard definitions afterward.

The change is stacked on `ea3d64526` (literal loop-call arguments). Measurements
below compare equally seeded opt2 compilers on the same source. They describe
this guard rewrite alone.

| Case | Parent Ir | New Ir | Change |
|---|---:|---:|---:|
| opt_runtime_string_eq | 1,402,401 | 802,415 | -42.8% |
| opt_string_scan | 211,769 | 141,769 | -33.1% |

All 45 paired benchmark outputs match Clang. Forty-three assembly files are
byte-identical to the parent; only these two cases change. Their text sizes
fall from 9,204 to 8,854 bytes and from 8,028 to 8,021 bytes, respectively.
No instruction baseline is raised.

Fifteen interleaved, rotated CPU-14 samples on the Ryzen 9 9950X give these
medians (milliseconds). One warmup precedes each case; arguments use 20,000,000
string-equality rounds and 3,500,000 string-scan rounds to reduce startup noise.

| Case | Parent | New | Clang auto |
|---|---:|---:|---:|
| string equality | 7.188 | 5.020 | 1.272 |
| string scan | 1.913 | 1.862 | 96.288 |

String equality is still about 3.95 times slower than Clang here. Clang replaces
the repeated accumulation with a multiply, while this change still executes
that loop. The small string-scan timing difference is close to process-startup
cost; the instruction-count improvement is the clearer result.

Compiling `src/compiler_liveness.tl` at opt2 uses 32,664,560,001 versus
32,667,011,550 instructions (+0.0075%), with byte-identical assembly output.

The optimizer fixture checks both guard edges and the unchanged first-entry
path, absence of cache slots, fallback for work before the call, a multiply
defined call result and an explicit exit phi, and valid reconstructed SSA.
The runtime fixture covers zero/negative trips with a trapping callee that must
stay skipped, a non-unit stride, live exit state and wrapping recurrence.
All 141 optimizer tests and all 693 Linux integration cases pass. Both target
parity suites pass; the benchmark harness checks all 45 paired outputs.

Reproduce with `scripts/bench.sh --runs 5 --cpu 14`, and
`scripts/measure-instruction-counts.sh --benchmarks-only --cases
opt_runtime_string_eq,opt_string_scan --runs 1`, selecting each compiler with
`TYPELISP_BIN`. Detailed local artifacts are under `target/exp/guarded-call/`.
