# Preserve read-only call results across branch joins

A repeated read-only call after a branch join used to run again even when its
first result remained valid on every incoming path. The optimizer now intersects
predecessor exit tables by the exact single-definition result ID. Stores and
unknown calls invalidate entries; unvisited predecessors, backedges and distinct
branch-local results refuse reuse. No call is moved or speculated and no phi is
synthesized. This also applies between checked-inlining generations.

Each intersection inspects at most 64 entries from each table. It therefore
performs at most 4,096 result comparisons per predecessor, independent of the
number of available calls in a large function. Older entries are conservatively
forgotten at joins. Existing block-local and single-predecessor propagation are
unchanged. Without this bound, linear membership searches at every join made
large functions pay cubic work.

## Generated code

The paired `pure_call_join` benchmark computes a runtime-dependent integer mix,
a different mix in each branch, and the original mix again after the join. The
C baseline uses `uint64_t` to preserve wrapping. Executed instructions fall from
232,501,100 to **154,501,100** (−33.55%). The final bounded revision reproduces
154,501,100 exactly against upstream `f716205a`. The C scalar reference counts
218,406,456 with CI's clang (hosted run 35931103677); a local clang measured
218,104,889, and C rows are recorded from CI's toolchain (#7792). Both rows are
registered in the required `instruction-main` gate,
which also validates opt2 outputs against both C implementations. The manifest
keeps that gate's cases out of the duplicate correctness suites.

All 45 pre-existing benchmark assemblies are byte-identical to current main.
The separate write-free integration fixture emits one fewer call at opt2 than
main and checks a reference checksum at opt0, opt1 and opt2. The original fixture
continues to cover direct/called global writes and partial availability.

Earlier timing measurements against `e2206a24`, on Linux x86-64 / Ryzen 9 9950X
with Clang 22.1.8, used 15 rotated rounds pinned to CPU 8:

| Implementation | Median ms |
| --- | ---: |
| Upstream TypeLisp | 33.527 |
| TypeLisp with join reuse | 22.832 |
| Clang `-O2` | 32.967 |

Clang's inlining choices leave repeated work in this particular benchmark;
these results compare the complete default pipelines on this case. They do not
establish general LLVM parity. The bounded revision retains the same benchmark
instruction count. The host is shared, and short wall-time differences are noisy.

## Compile-time bound

An adversarial source generator creates N available pure-call results followed
by N if-joins. Single diagnostic compiles, opt2, same source and host, pinned to
CPU 14 with compiler order rotated by size:

| N | Current main ms | Unbounded PR ms | Bounded PR ms |
| --- | ---: | ---: | ---: |
| 500 | 367 | 705 | 343 |
| 1,000 | 900 | 3,705 | 1,032 |
| 2,000 | 3,529 | 27,820 | 3,457 |

These are single observations demonstrating the former scaling failure, not
precise timing estimates. The fixed 64-entry bounds establish the work limit
independently of timing. Normal compiler-cost measurements for the original
revision were +0.0144% Ir on `compiler_liveness.tl`; that historical figure is not
relabelled as a measurement of the revised compiler. The CI-owned self-compile
baseline is unchanged.

## Validation

- 143 optimizer tests, including exact retained-Call assertions for every
  refused join and boundary coverage for both bounded table walks.
- All 700 Linux integrations, including the write-free fixture whose assembly
  demonstrably removes the repeated call.
- All 46 paired opt2 benchmarks, three interleaved rounds with exact
  output/status checks; the new required instruction-count rows match exactly.
- Canonical bootstrap fixpoint and embedded-image provenance.
- Codegen and backend assembly target-parity gates.
- Formatting, lint, implementation-language and diff checks.

Artifacts are in `target/exp/call-joins/revision/`: `scale/`, `bench/`,
`main-assembly/`, `live-{base,fixed}.s`, `counts-registered/` and gate logs.
