# Compact vector identity compile cost

Issue #5609 measures the proof-guided skip lane for five distinct compact
`(vector.vector T core)` identities. The paired fixtures request the same
`new`, `push`, and `get` surface from every identity:

- `tests/integration/compile_profile_vector_one_core.tl`
- `tests/integration/compile_profile_vector_five_core.tl`

The comparison is current main commit
`fd19fade1ae04bb49fde42275480a652037e9912` versus branch commit
`63acfbbf3fdc943d1b11cf53ad8a5da8ecdb18d6`. The Cachegrind and self-compile
comparisons below are one paired local run, not the checked global baseline.
Cachegrind used equal-length compiler executable and output paths; the
self-compile gate used the exact archived main source with equal-length output
directories and compiler executable names. The paired Cachegrind invocations
were:

```sh
TYPELISP_BIN=target/5609-measure-bin/mainxx \
  scripts/attic/measure-vector-instantiation-cost.sh --runs 1 \
  --output target/5609-vector-mainxx
TYPELISP_BIN=target/5609-measure-bin/branch \
  scripts/attic/measure-vector-instantiation-cost.sh --runs 1 \
  --output target/5609-vector-branch
```

The current-main phase counters and allocation were regenerated inside the
exact archived origin/main tree; branch values were regenerated inside the
branch tree. The `mainxx`/`branch` compiler aliases and corresponding output
roots are intentionally equal-length.

The run did not edit or ratchet `perf/insn-exec-baseline.tsv`.

## Cachegrind

Values are instruction references (`Ir`); the incremental column is the
one-to-five difference within each revision.

| revision | one identity | five identities | incremental delta |
| --- | ---: | ---: | ---: |
| current main | 146,569,462 | 187,449,041 | 40,879,579 |
| branch | 146,601,172 | 187,381,329 | 40,780,157 |
| branch minus main (absolute) | +31,710 | -67,712 | -99,422 |

The branch saves 99,422 `Ir` on the one-to-five increment, or 0.2432070% of
main's increment. The one-identity absolute compile is +31,710 `Ir`; this is
not a claim of an absolute one-identity improvement.

## Concrete typecheck and allocation

These allocations use each revision's own source tree: current-main values
were regenerated inside the exact archived origin/main tree, and branch values
inside the branch tree. Values are one / five identities, and the increment is
five minus one.

| measurement | current main | branch | branch minus main (absolute) | incremental savings |
| --- | ---: | ---: | ---: | ---: |
| `lower.typecheck` bytes | 2,298,192 / 2,700,168 | 2,332,168 / 2,701,816 | +33,976 / +1,648 | 32,328 (8.0422712%) |
| total allocation bytes | 71,496,872 / 77,625,248 | 71,531,576 / 77,627,536 | +34,704 / +2,288 | 32,416 (0.5289493%) |
| one-to-five increment | 401,976 | 369,648 | -32,328 | — |
| one-to-five increment (total) | 6,128,376 | 6,095,960 | -32,416 | — |

## Proof-reuse counters

Counters are one / five identities. The proof-reused counter is absent on
current main and is semantically zero there.

| counter | current main | branch |
| --- | ---: | ---: |
| generated declaration checks | 11 / 55 | 11 / 39 |
| invariant-eligible declarations | 3 / 15 | 11 / 55 |
| concrete-required declarations | 8 / 40 | 0 / 0 |
| proof-reused declarations | 0 / 0 | 0 / 16 |
| generated-module abstract proofs | 1 / 1 | 1 / 1 |

The 16 reused proofs are four admitted declarations reused for each of the
four identities after the first (`4 × 4`). The first identity remains fully
checked. All 11 declarations are eligibility candidates; the exact
proof/rule/structure guard admits four, while every other declaration stays on
the normal concrete-check path; this is the intended conservative negative
coverage. Literal narrowing, clone/equality, bool arithmetic, cleanup/ownership,
reflection/fixed shapes, and nested generated imports therefore remain on the
concrete path whenever the proof/family/identity/lookup/structure guard does
not match. The accounting remains exact: checks plus
proof reuse equals invariant-eligible plus concrete-required (11 = 11 for one;
39 + 16 = 55 for five).

## Downstream output

Downstream counters are unchanged between main and branch. Values are one /
five identities, and generated fixture assembly is byte-identical for both
fixtures.

| downstream counter | main and branch |
| --- | ---: |
| checked pre-declarations | 202 / 262 |
| checked functions entering lowering | 131 / 175 |
| reachable declarations | 103 / 159 |
| reachable functions | 32 / 72 |
| emitted IR functions | 32 / 72 |
| emitted IR blocks | 76 / 219 |
| emitted IR instructions | 407 / 1,147 |

## Same-host self-compile gate

The exact archived main source was self-compiled on the same host, with
equal-length output directories and compiler executable names. Main measured
61,776,694,992 `Ir`; the branch measured 62,043,310,180 `Ir`.

The delta is +266,615,188 (`+0.4315789%`). The unchanged +0.5% gate allows
308,883,474 `Ir`, leaving 42,268,286 `Ir` of headroom. This is a gate check,
not a stable elapsed-time or cross-host benchmark; the checked global
instruction baseline was not edited.

## Generated compiler assembly and bootstrap

| assembly metric | current main | branch | branch delta |
| --- | ---: | ---: | ---: |
| bytes | 54,355,503 | 54,241,083 | -114,420 (-0.2105031%) |
| lines | 1,719,167 | 1,716,963 | -2,204 |
| defined symbols | 18,287 | 18,231 | -56 |

The Linux bootstrap fixpoint passed (`stage2 == stage3`) and embedded-stdlib
parity; the branch stage3 binary is 9,937,496 bytes.

## Windows hard-4-GiB capacity gate

These measurements use revision-matched source trees with the same compile
flags and hard cap. The hard cap is 4,294,967,296 bytes; elapsed time is
included for reproducibility, but the purpose of this table is the memory
gate.

| opt | run | elapsed ms | working bytes | private bytes | job bytes (% of cap) |
| --- | --- | ---: | ---: | ---: | ---: |
| opt1 | main | 87,500 | 1,035,603,968 | 1,149,198,336 | 1,167,265,792 (27.1775%) |
| opt1 | branch | 89,896 | 1,008,685,056 | 1,124,286,464 | 1,142,353,920 (26.5975%) |
| opt2 | main | 97,533 | 1,565,081,600 | 1,695,494,144 | 1,700,941,824 (39.6031%) |
| opt2 | branch | 106,539 | 1,575,899,136 | 1,712,599,040 | 1,713,848,320 (39.9036%) |

For opt1, branch job memory is -24,911,872 bytes (-2.134207%) versus main. For
opt2, it is +12,906,496 bytes (+0.758785%). Both branch runs complete under
the hard cap.

The actual normal `intern-capacity()` is 131,072 slots, and the final
Windows-target compiler compiled `src/main.tl`, assembled, and linked
successfully at that fixed capacity. The resulting artifacts are 68,760,044
bytes of assembly, 16,664,894 bytes of object code, and 13,627,392 bytes of
executable. Expanded-capacity results cannot be projected linearly onto fixed
capacity; the direct fixed-capacity compile/link is authoritative. In a
controlled A/B using the exact same expanded compiler, flags, build identity,
and embedded artifact against archived pre-lint commit `33a5c9629`, both
pre-lint and final source produced exactly `pool=79,334`, `generated_next=79,370`,
`generated_count=59,893`, and nominal mapped `-8,156`. This demonstrates
source neutrality only; the earlier +36 comparison was environment-confounded
and is not final evidence. #5211 owns the growable interner replacement.
