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

The ISPC and TypeLisp sources keep both stores fused in one `foreach`, and the
TypeLisp source spells the upstream `x * cos - y * sin` expression directly.
TypeLisp's multi-destination contiguous-map lowering emits one SIMD loop and
shares the repeated scaled-input subexpressions before the two ordered stores.
Kernel-only metrics compare the complete exported output contract on the same
fused shape; TypeLisp retains its checked full-width and tail paths.

Six checked lengths cover empty (0), sub-gang (3), exact AVX2 and AVX-512
gangs (8 and 16), a tail (19), and an unrolled full-gang path followed by a
tail (275). The fixtures include negative coordinates and scales, zero
strength, and nontrivial `(sin, cos)` pairs. Identity-rotation cases are exact
and checked against fixed formulas. Nontrivial rotations reject non-finite
values and allow at most two ULPs relative to the scalar binary32 operation
sequence, accounting only for legal ISPC FMA contraction. Both output arrays
retain an out-of-range sentinel.

Run required TypeLisp and scalar-C correctness (including at most four
bounds-abort sites in the TypeLisp kernel) and optional real ISPC comparisons
with:

```sh
scripts/verify-codegen-cases.sh --only 'point_transform-*' tests/codegen/ispc.cases
ISPC_BIN=/path/to/ispc scripts/verify-codegen-cases.sh --only 'point_transform-*' tests/codegen/ispc.cases
ISPC_POINT_TRANSFORM_AVX512=1 ISPC_BIN=/path/to/ispc \
  scripts/verify-codegen-cases.sh --only 'point_transform-*' tests/codegen/ispc.cases
```

Kernel-only assembly metrics come from `scripts/measure-ispc-spmd.sh` (see
[`../README.md`](../README.md)).
