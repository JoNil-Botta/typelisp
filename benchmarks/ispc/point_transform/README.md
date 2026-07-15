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

The ISPC source keeps both stores fused in one `foreach`. TypeLisp's current
contiguous SIMD recognizer accepts one destination per map, so `bench.tl`
preserves the same two-output contract as two maps over the identical range.
That intentionally repeats input loads and scale products rather than hiding
the missing fusion in hand-written aggregate or pointer code. Kernel-only
metrics therefore compare the complete exported output contract and make the
fusion gap visible.

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

On the initial Linux x86-64 run with the official v1.31.0 binary, AVX2 recorded
442 TypeLisp versus 63 ISPC kernel instructions, 15 versus 12 packed-f32 ops,
zero versus four FMAs, and 141 versus zero conservative spill candidates.
AVX-512 recorded 465 versus 61 instructions, 30 versus 12 packed-f32 ops, zero
versus four FMAs, and 135 versus zero spill candidates. TypeLisp's two maps and
their safety/tail paths account for the visible duplication; #5072 tracks fused
multi-destination lowering rather than normalizing this report around the gap.
