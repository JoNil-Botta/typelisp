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

A Linux x86-64 run after direct gather lowering recorded the following
kernel-symbol census. TypeLisp uses checked 64-bit indices (`vgatherqps`), while
the pinned ISPC v1.31.0 comparison converts its f32 offsets to 32-bit indices
and emits `vgatherdps`. Scalar TypeLisp has zero hardware gathers and uses
checked scalar lane extraction.

| Mode/implementation | SHA-256 | Bytes | Instructions | Branches | Calls | Spill candidates | GPR/vector/mask registers | Gathers | Stack accesses |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| scalar / TypeLisp | `df6d09703ca21486f1a30d9c383700b3b90c1ead2ecb15787b613fc8258d6db8` | 2,881 | 95 | 18 | 10 | 0 | 14 / 5 / 0 | 0 | 0 |
| AVX2 / TypeLisp | `a4524ef6d89445db032f3da1486757dab59d1b2dda4a9c3b21ef9e0999cc0839` | 6,878 | 255 | 21 | 11 | 68 | 13 / 13 / 0 | 2 | 82 |
| AVX2 / ISPC | `0a75fad4342cfc9c552a80b66c2eb66c97d54858cd3f77f72ad3c2db76dfed61` | 1,711 | 51 | 5 | 0 | 0 | 7 / 13 / 0 | 2 | 0 |
| AVX-512 / TypeLisp | `af80f28bff20d8a7e2cf1a490b4f8db116e5c760a7e68b05894831184679bff8` | 8,935 | 342 | 29 | 19 | 82 | 13 / 12 / 1 | 2 | 104 |
| AVX-512 / ISPC | `8dd3f7fb32fe80121f0977a5b610f875bba9793b3d816507edea32a717f04f32` | 1,680 | 49 | 5 | 0 | 0 | 7 / 11 / 4 | 2 | 0 |

Removing index materialization reduced the TypeLisp kernel from 4,202 to 2,881
bytes and 153 to 95 instructions in scalar mode, from 11,024 to 6,878 bytes and
397 to 255 instructions in AVX2 mode, and from 12,970 to 8,935 bytes and 476 to
342 instructions in AVX-512 mode. The remaining TypeLisp gap is reported rather
than normalized away: it includes checked array accesses, runtime support
calls, and current vector spills.
