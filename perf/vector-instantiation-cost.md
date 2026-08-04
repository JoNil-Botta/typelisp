# Compact vector identity compile cost

Issue #5609 measures the proof-guided skip lane for five distinct compact
`(vector.vector T core)` identities. The paired fixtures request the same
`new`, `push`, and `get` surface from every identity:

- `tests/integration/compile_profile_vector_one_core.tl`
- `tests/integration/compile_profile_vector_five_core.tl`

The comparison is current main commit
`6009db052d6da786476096cf2118044e28867fc6` versus branch commit
`54aa0613dc4b18a0caca2222d4c7b531cde79502`. The Cachegrind and self-compile
comparisons below are one paired local run, not the checked global baseline.
The exact equal-length detached clones are `target/5609-final-mainxxxx` and
`target/5609-final-branchxx`; both were bootstrapped from the same seed into
the same relative `target/bootstrap` path, with `stage2.s == stage3.s` and
embedded parity. Cachegrind used equal-length compiler executable and output
paths. The paired Cachegrind invocations were:

```sh
(
  cd target/5609-final-mainxxxx &&
    TYPELISP_BIN=target/bootstrap/stage3 \
      scripts/attic/measure-vector-instantiation-cost.sh --runs 1 \
      --output target/vector-final
)
(
  cd target/5609-final-branchxx &&
    TYPELISP_BIN=target/bootstrap/stage3 \
      scripts/attic/measure-vector-instantiation-cost.sh --runs 1 \
      --output target/vector-final
)
```

The base and branch phase counters and allocation were regenerated from these
detached clones. The clone roots are equal-length, and each invocation uses the
same relative `target/bootstrap/stage3` compiler path and `target/vector-final`
output path.

The run did not edit or ratchet `perf/insn-exec-baseline.tsv`.

## Cachegrind

Values are instruction references (`Ir`); the incremental column is the
one-to-five difference within each revision.

| revision | one identity | five identities | incremental delta |
| --- | ---: | ---: | ---: |
| current main | 148,423,755 | 189,602,940 | 41,179,185 |
| branch | 148,781,602 | 189,755,874 | 40,974,272 |
| branch minus main (absolute) | +357,847 | +152,934 | -204,913 |

The branch saves 204,913 `Ir` on the one-to-five increment, or 0.4976131% of
main's increment. The one-identity absolute compile is +357,847 `Ir`; this is
not a claim of an absolute one-identity improvement.

## Concrete typecheck and allocation

These allocations use each detached clone: base values were regenerated inside
`target/5609-final-mainxxxx`, and branch values inside
`target/5609-final-branchxx`. Values are one / five identities, and the
increment is five minus one.

| measurement | current main | branch | branch minus main (absolute) | incremental savings |
| --- | ---: | ---: | ---: | ---: |
| `lower.typecheck` bytes | 2,298,088 / 2,699,968 | 2,331,888 / 2,702,128 | +33,800 / +2,160 | 31,640 (7.8729969%) |
| total allocation bytes | 71,538,544 / 77,612,408 | 71,571,928 / 77,616,136 | +33,384 / +3,728 | 29,656 (0.4882559%) |
| one-to-five increment | 401,880 | 370,240 | -31,640 | — |
| one-to-five increment (total) | 6,073,864 | 6,044,208 | -29,656 | — |

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
five identities. SHA-256 confirms that the main and branch assembly are
identical for the one-identity fixture and identical for the five-identity
fixture.

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

The base source was self-compiled on the same host, with equal-length output
directories and compiler executable names. Main measured 62,699,904,250 `Ir`;
the branch measured 62,958,641,588 `Ir`.

The delta is +258,737,338 (`+0.4126599%`). The +0.5% gate allows 313,499,521
`Ir`, leaving 54,762,183 `Ir` of headroom. This is a gate check, not a stable
elapsed-time or cross-host benchmark; the checked global instruction baseline
was not edited.

## Generated compiler assembly and bootstrap

| assembly metric | current main | branch | branch delta |
| --- | ---: | ---: | ---: |
| bytes | 54,436,108 | 54,670,126 | +234,018 (+0.4298948%) |
| lines | 1,721,043 | 1,728,434 | +7,391 |
| defined symbols | 18,200 | 18,305 | +105 |

Both detached clones were formatter-stable: the bootstrap fixpoint passed
(`stage2 == stage3`) with embedded parity. The base stage3 binary is 10,008,840
bytes; the final6 branch stage3 binary is 10,042,576 bytes.

## Windows hard-4-GiB capacity gate

These measurements use the paired detached clones with the same compile flags
and hard cap. The hard cap is 4,294,967,296 bytes; elapsed time is included
for reproducibility and is not a comparative performance claim. The purpose
of this table is the memory gate.

| opt | run | elapsed ms | working bytes | private bytes | job bytes (% of cap) |
| --- | --- | ---: | ---: | ---: | ---: |
| opt1 | main | 88,367 | 1,055,543,296 | 1,170,800,640 | 1,188,864,000 (27.6803970%) |
| opt1 | branch | 89,435 | 1,060,200,448 | 1,179,463,680 | 1,197,527,040 (27.8820992%) |
| opt2 | main | 105,477 | 1,577,279,488 | 1,712,865,280 | 1,714,102,272 (39.9095535%) |
| opt2 | branch | 105,491 | 1,588,678,656 | 1,725,829,120 | 1,727,078,400 (40.2116776%) |

For opt1, branch job memory is +8,663,040 bytes (+0.7286822%) versus main. For
opt2, it is +12,976,128 bytes (+0.7570218%). Both paired runs complete under
the hard cap.

The actual normal `intern-capacity()` remains 131,072 slots. The authoritative
normal-capacity branch Windows compiler compiled, assembled, and linked
successfully; the resulting artifacts are 69,270,784 bytes of assembly,
16,802,867 bytes of object code, and 13,753,856 bytes of executable. Merged
#6258/#6293 removed the collision by routing lowering-derived symbols through
the IR-owned growable table. This #5609 change does not alter interner storage;
the growable-table behavior belongs to those merged fixes.
