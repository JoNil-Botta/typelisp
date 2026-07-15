# ISPC point transform

This case ports the vector body of
`examples/cpu/point_transform_ctypes/point_transform.ispc::transform_points`
from ISPC v1.31.0 at commit
`c6adb4f86f5678ce6c41951b1e2b59f727455697`. The derived ISPC source retains
its BSD-3-Clause notice and preserves scaling, rotation, translation, strength,
the four structure-of-arrays buffers, binary32 arithmetic, and the `foreach`
range.

The upstream kernel computes uniform `sin(rotation)` and `cos(rotation)` before
the loop. TypeLisp deliberately has no freestanding transcendental surface, so
both versions receive identical exact binary32 sine/cosine values. Transform
fields are also passed as uniform scalars: this isolates the f32 zip kernel and
does not turn the case into an unrelated C struct-ABI comparison. No libm work
occurs in the correctness or measured region.

The ISPC and TypeLisp sources keep both stores fused in one `foreach`.
TypeLisp's multi-destination contiguous-map lowering emits one SIMD loop and
shares the repeated scaled-input subexpressions before the two ordered stores.
Kernel-only metrics compare the complete exported output contract on the same
fused shape; TypeLisp retains its checked full-width and tail paths.

Five checked lengths cover empty (0), sub-gang (3), exact AVX2 and AVX-512
gangs (8 and 16), and a tail (19). The fixtures include negative coordinates
and scales, zero strength, and nontrivial `(sin, cos)` pairs. Identity-rotation
cases are exact and checked against fixed formulas. Nontrivial rotations reject
non-finite values and allow at most two ULPs relative to the scalar binary32
operation sequence, accounting only for legal ISPC FMA contraction. Both output
arrays retain an out-of-range sentinel.

Run required TypeLisp and scalar-C correctness, optional real ISPC comparisons,
and kernel-only assembly metrics with:

```sh
scripts/verify-ispc-point-transform.sh
ISPC_BIN=/path/to/ispc scripts/verify-ispc-point-transform.sh
ISPC_POINT_TRANSFORM_AVX512=1 ISPC_BIN=/path/to/ispc \
  scripts/verify-ispc-point-transform.sh
```

Raw assembly and compiler logs plus `static.tsv` are written under
`target/ispc-point-transform-verify/`. The report records assembly hashes and
bytes, instruction/branch/call counts, packed-f32 and FMA shape, distinct
register classes, and conservative stack/spill candidates. It is report-only;
shared ratios, tool fingerprints, and optional retired-instruction summaries
remain owned by #4968.

The initial pre-fusion Linux x86-64 run with the official v1.31.0 binary
recorded 442 TypeLisp versus 63 ISPC AVX2 kernel instructions, 15 versus 12
packed-f32 ops, zero versus four FMAs, and 141 versus zero conservative spill
candidates. AVX-512 recorded 465 versus 61 instructions, 30 versus 12
packed-f32 ops, zero versus four FMAs, and 135 versus zero conservative spill
candidates. Those values remain the checked before baseline for #5072; current
reports show the fused lowering's direct after measurements. With the same
official v1.31.0 tool and compiler settings, fusion changes AVX2 from 442
instructions / 11,585 bytes / 15 packed-f32 ops / 141 spill candidates
(`3b3838dff14abbf57c6f7b04b28c1b5cff85e21ff74b884aa730d59b760a4151`)
to 288 / 7,576 / 13 / 85
(`98ef7ca139ac75acc0819725cd63f8f8a0d445a43256e8df3a0caa502c56fa39`).
AVX-512 changes from 465 instructions / 12,460 bytes / 30 packed-f32 ops /
135 spill candidates
(`3240fb693e4818787df627c8fec7c1ce56dee783b9514c4b987a0f256ba0e7a2`)
to 309 / 8,234 / 26 / 89
(`b65cde583f0c1c2dc0e6aaa4082466fabe8487d54bb36a7689d19790a0d9779d`).
TypeLisp FMA count remains zero before and after; ISPC retains four FMAs, an
independent follow-up rather than part of loop/store fusion.
