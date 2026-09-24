# Factored address multipliers

For a register-resident byte address such as `base + index * 24`, the backend
can emit `lea index*3` followed by `lea base+temporary*8`. This replaces the
multiply and address addition with two LEAs, using the existing register homes.
The supported strides are 6/12/24, 10/20/40, and 18/36/72. The arithmetic has the
same 64-bit wraparound behavior.

The multiplier's result must have exactly one use in the whole function, in the
adjacent byte Gep. The address must need materialization. Spills, a temporary
that aliases the base, an `%rbp` source/base, and a nonzero folded displacement
all decline. A successful match consumes exactly one Gep fold ordinal; rejected
probes consume none. Targets and register allocation are unchanged.

## Measurements

Linux x86-64, Ryzen 9 9950X, Clang 22.1.8 `-O2`, TypeLisp opt 2. Timings are
15 interleaved paired samples pinned to CPU 14, after warm-up. Instruction counts
use Cachegrind with cache/branch simulation disabled and guest chasing disabled.
The upstream comparison is `7192557cd`; the affected benchmark assembly is also
byte-identical to the earlier `efa1cd4ed` used for the timing run.

A local copy of `hashmap_get` increases its round constant from 1,200 to 120,000
in both languages, so process startup does not dominate:

| Implementation | Median elapsed |
| --- | ---: |
| Upstream TypeLisp | 447.621 ms |
| Factored addresses | 436.800 ms |
| Clang `-O2` | 743.751 ms |

This is a 2.4% improvement over upstream on this lookup workload. The ordinary
lookup benchmark moves from 5.624 to 5.544 ms. Churn, growth, insertion and the
s-expression reader are approximately neutral; no speedup is claimed for them.
The reader was run with its token corpus and 10 rounds.

All 47 benchmark assemblies were compared. Only these five change, exclusively
by replacing adjacent multiply/address pairs. Their executable text sizes and
executed instruction counts are unchanged:

| Benchmark | TypeLisp Ir, three identical samples | Text bytes |
| --- | ---: | ---: |
| hashmap_churn | 3,479,195 | 7,255 |
| hashmap_get | 131,359,159 | 7,017 |
| hashmap_grow | 1,319,115 | 6,841 |
| hashmap_insert | 23,036,363 | 6,940 |
| read_sexpr | 725,524,506 | 18,479 |

Compiling the same `route_http` source to the same output path costs
4,096,083,269 Ir upstream and 4,096,075,249 Ir with this change; the generated
assembly is byte-identical. This is effectively neutral compiler cost. No
performance baselines are raised or replaced.

## Regression coverage

The backend test checks 3,600 combinations of constants, types, Linux/Windows
policy, register aliases and spills, extra uses in another block, and Gep fold
state. It verifies refusal leaves the fold cursor unchanged and acceptance
consumes only the matched address.

The runtime fixture reads arrays with all nine supported strides against an
arithmetic oracle. Its opt-2 assembly exercises all nine replacements. A tenth
case keeps the complete byte offset live and must preserve it. All cases run
at opt 0/1/2 on both integration manifests; the independently calculated output
is `257269108`.

The full local checks include inline and Linux integration tests, backend smoke,
bootstrap fixpoint and embedded provenance, compile profiling and the native
route size gate, native Linux linking, both target parity suites, lint, formatting
and implementation-language policy. Hosted CI supplies Windows execution.
