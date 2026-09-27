# ISPC perfbench `gathers`

This case ports `examples/cpu/perfbench/perfbench.ispc::gathers` from ISPC
v1.31.0 at commit `c6adb4f86f5678ce6c41951b1e2b59f727455697`.
The derived source retains its BSD-3-Clause attribution and keeps the original
per-lane offset load, non-contiguous f32 read, accumulation, horizontal sum,
signature, and 100-call perfbench repetition structure.

The TypeLisp kernel stores offsets as `i64` because no foreign ABI is measured,
but otherwise preserves `values[i + offsets[program-index]]`. The offset pattern
`0,3,1,4,2,0,4,1` has distinct and repeated lanes. Inputs are integer-valued
binary32 values and every sum stays below 2^24, so scalar and regrouped SIMD
results are bit-identical. Cases cover empty, scalar-exact, sub-gang, x8/x16
exact, tail, and 65,536-element ranges. Five safe padding elements cover the
largest active offset while making an incorrectly active tail lane unsafe.

Run required TypeLisp/C-oracle correctness, focused bounds/scatter safety, and
optional pinned ISPC comparisons with:

```sh
scripts/verify-codegen-cases.sh --only 'perfbench_gathers-*' tests/codegen/ispc.cases
ISPC_BIN=/path/to/ispc scripts/verify-codegen-cases.sh --only 'perfbench_gathers-*' tests/codegen/ispc.cases
```

`bounds.tl` keeps the deliberate active-lane out-of-bounds probe outside the
timed `gathers` symbol while exercising the same gather-reduction lowering in
scalar, AVX2, and AVX-512 modes.

TypeLisp SIMD modes use checked 64-bit indices (`vgatherqps`), while the pinned
ISPC comparison converts its offsets to 32-bit indices (`vgatherdps`); scalar
TypeLisp uses checked scalar lane loads. The kernel-only static comparison
comes from `scripts/measure-ispc-spmd.sh --cases perfbench_gathers` (see
[`../README.md`](../README.md)).
