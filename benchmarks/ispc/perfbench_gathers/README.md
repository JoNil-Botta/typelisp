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
scripts/verify-ispc-perfbench-gathers.sh
ISPC_BIN=/path/to/ispc scripts/verify-ispc-perfbench-gathers.sh
```

`bounds.tl` keeps the deliberate active-lane out-of-bounds probe outside the
timed `gathers` symbol while exercising the same gather-reduction lowering in
scalar, AVX2, and AVX-512 modes.

The shared static comparison, including kernel-only gather/vector/register/
spill census and assembly hashes, is generated with:

```sh
scripts/measure-ispc-spmd.sh --cases perfbench_gathers
ISPC_BIN=/path/to/ispc scripts/measure-ispc-spmd.sh --cases perfbench_gathers
```

A real Linux x86-64 run with the pinned v1.31.0 binary recorded the following
kernel-symbol census. TypeLisp uses checked 64-bit indices (`vgatherqps`), while
ISPC converts its f32 offsets to 32-bit indices and emits `vgatherdps`. Scalar
TypeLisp has zero hardware gathers and uses checked scalar lane extraction.

| Mode/implementation | SHA-256 | Bytes | Instructions | Branches | Calls | Spill candidates | GPR/vector/mask registers | Gathers | Stack accesses |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| scalar / TypeLisp | `15fc5cc040e83086e4b525807e015f1cf6f5cf1606efb2583ec6af02d2575333` | 4,202 | 153 | 25 | 14 | 9 | 20 / 5 / 0 | 0 | 9 |
| AVX2 / TypeLisp | `47ef62ce7fe03d81951fe96b153c1ccd4c248fbb897c84453dfacbb4e767762e` | 11,024 | 397 | 43 | 23 | 109 | 15 / 14 / 0 | 2 | 125 |
| AVX2 / ISPC | `0a75fad4342cfc9c552a80b66c2eb66c97d54858cd3f77f72ad3c2db76dfed61` | 1,711 | 51 | 5 | 0 | 0 | 7 / 13 / 0 | 2 | 0 |
| AVX-512 / TypeLisp | `21f9f55b796df461463349a95cd4503d978449608e07cc99a5beec9a92e1bd57` | 12,970 | 476 | 51 | 31 | 123 | 15 / 13 / 1 | 2 | 139 |
| AVX-512 / ISPC | `8dd3f7fb32fe80121f0977a5b610f875bba9793b3d816507edea32a717f04f32` | 1,680 | 49 | 5 | 0 | 0 | 7 / 11 / 4 | 2 | 0 |

The large TypeLisp gap is reported rather than normalized away: it includes
the explicit index-materialization loop, checked array accesses, runtime
support calls, and current vector spills. Follow-up #5116 tracks direct
computed-index gather lowering so this port can remove the materialization
without changing semantics or the safety contract.
