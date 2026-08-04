# Compact vector identity compile cost

Issue #5609 measures the proof-guided skip lane for five distinct compact
`(vector.vector T core)` identities. The paired fixtures demand the same
`new`, `push`, and `get` surface from every identity:

- `tests/integration/compile_profile_vector_one_core.tl`
- `tests/integration/compile_profile_vector_five_core.tl`

The diagnostic harness is:

```sh
TYPELISP_BIN=tools/stage0-linux/typelisp \
  scripts/attic/measure-vector-instantiation-cost.sh --runs 1
```

It does not read or update `perf/insn-exec-baseline.tsv`.

## Cachegrind result

The before measurement is current main `6d53502c3`; the after measurement is
the proof-reuse branch. Both were measured with the same vector fixtures and
host harness.

| fixture | current main `Ir` | proof-reuse branch `Ir` |
| --- | ---: | ---: |
| one compact identity | 148,649,592 | 148,966,817 |
| five compact identities | 190,176,771 | 190,476,378 |
| one-to-five incremental delta | 41,527,179 | 41,509,561 |

The second-through-fifth incremental cost therefore improves by exactly 17,618
Ir, or 0.0424%, against main's one-to-five incremental delta. The absolute
branch one- and five-identity compiles are slightly higher, so this is a small
incremental win rather than a claim of a lower absolute compile cost.

## Concrete typecheck allocation

| measurement | one identity | five identities |
| --- | ---: | ---: |
| current main | 3,104,448 | 4,085,976 |
| proof-reuse branch | 3,104,616 | 3,976,872 |
| branch minus main | +168 | -109,104 |

## Proof-reuse lane counters

Counters are shown as `one / five` identities.

| counter | current main | proof-reuse branch |
| --- | ---: | ---: |
| generated declaration checks | 11 / 55 | 11 / 35 |
| invariant-eligible declarations | 3 / 15 | 11 / 55 |
| concrete-required declarations | 8 / 40 | 0 / 0 |
| proof-reused declarations | 0 / 0 | 0 / 20 |
| generated-module abstract proofs | 1 / 1 | 1 / 1 |

The 20 skipped checks are exactly five safe declarations reused across the
four identities after the first (`5 × 4`). The first identity still receives
full concrete declaration checking, preserving its diagnostics. The negative
coverage remains conservative: literal narrowing, clone/equality, bool
arithmetic, cleanup/ownership, reflection/fixed shapes, and nested generated
imports all remain on the normal concrete-check path whenever the proof,
family, identity, lookup, or structural conditions do not match.

## Downstream output

The proof-reuse branch is unchanged from main at every reported downstream
boundary. Values are `one / five` identities.

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

For `self_compile/compile_cli_opt1`, current main measured
65,644,598,463 instructions and the branch measured 65,913,128,336: a delta
of +268,529,873 (+0.4091%). This remains within the unchanged +0.5% gate. The
checked absolute instruction baseline is CI-owned and was not edited: the
branch result is not a downward ratchet, and absolute local counts are
environment-specific.

## Generated compiler assembly

| assembly metric | current main | proof-reuse branch |
| --- | ---: | ---: |
| bytes | 54,497,807 | 54,889,027 |
| lines | 1,963,869 | 1,977,042 |
| text symbols | 18,124 | 18,232 |

The assembly byte delta is +391,220 (+0.7179%).

## Windows hard-4-GiB measurements

These are the hard-4-GiB compile runs, with main measured first and the branch
second. Every branch workload completes below 4,294,967,296 bytes.

| opt level | run | elapsed ms | working bytes | private bytes | job bytes |
| --- | --- | ---: | ---: | ---: | ---: |
| opt1 | main | 8,433 | 1,274,961,920 | 2,743,525,376 | 2,765,787,136 |
| opt1 | branch | 7,202 | 1,283,919,872 | 3,284,054,016 | 3,285,307,392 |
| opt2 | main | 19,877 | 2,159,562,752 | 3,655,483,392 | 3,677,728,768 |
| opt2 | branch | 17,707 | 2,197,008,384 | 4,191,797,248 | 4,193,046,528 |
