# ISPC perfbench `stores`

This case ports `examples/cpu/perfbench/perfbench.ispc::stores` from ISPC
v1.31.0 at commit `c6adb4f86f5678ce6c41951b1e2b59f727455697`.
The derived ISPC source retains its BSD-3-Clause attribution and exact upstream
body. The TypeLisp port preserves the lane-indexed `zeros` load, contiguous
`foreach` stores, and 100-call perfbench repetition structure.

Upstream converts each loaded f32 through `int` before storing it as f32.
TypeLisp currently has no SIMD numeric-conversion IR, so `bench.tl` uses direct
f32 loads and stores with distinct integer-valued binary32 inputs. The direct
and converted results are therefore byte-identical; the adaptation does not
hide lane mapping, mask, or tail errors.

The checked lengths are empty (0), sub-gang (3), exact generic/AVX2/AVX-512
gangs (4, 8, and 16), a tail (19), and a longer perf case (65,536). Every
output byte plus the first out-of-range sentinel is checked. Exit codes expose
the observed gang width: 42 for scalar x1, 49 for AVX2 x8, and 57 for AVX-512
x16. ISPC v1.31.0 has no width-1 target, so the scalar side uses the checked C
oracle; generic x4 is a derived-kernel check only.

Run required TypeLisp and C-oracle correctness and optional ISPC comparisons
with:

```sh
scripts/verify-codegen-cases.sh --only 'perfbench_stores-*' tests/codegen/ispc.cases
ISPC_BIN=/path/to/ispc scripts/verify-codegen-cases.sh --only 'perfbench_stores-*' tests/codegen/ispc.cases
```

The TypeLisp AVX2 shape is one full x8 vector load/store loop plus a scalar
tail; AVX-512 uses an x16 loop plus a masked load/store tail. Kernel-only
report metrics come from `scripts/measure-ispc-spmd.sh` (see
[`../README.md`](../README.md)); they are not a baseline.
