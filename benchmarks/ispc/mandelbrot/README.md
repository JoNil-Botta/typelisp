# Mandelbrot varying-loop comparison

This case ports `examples/cpu/mandelbrot/mandelbrot.ispc` from ISPC v1.31.0
at commit `c6adb4f86f5678ce6c41951b1e2b59f727455697`. The derived ISPC source keeps
the upstream BSD-3-Clause notice and the single-threaded `mandel` /
`mandelbrot_ispc` path. It deliberately excludes `mandelbrot_tasks`.

The TypeLisp port preserves binary32 coordinate arithmetic, row-major
traversal, the radius-squared `> 4` escape test, the maximum-iteration limit,
and i32 output counts. Coordinate arrays are prepared once per row because the
current masked SPMD lane-width analysis cannot mix the i64 `foreach` index with
16-wide f32 arithmetic. They are allocated at exactly `width`, so the 19-pixel
tail traps if an inactive lane evaluates a coordinate load.

ISPC updates `z_re` and `z_im` in an `unmasked` block after divergent lanes
break. TypeLisp represents the remaining budget explicitly: escaped lanes set
it to zero, active lanes update their state and decrement it, and a lane retires
permanently when the varying-while condition becomes false. Retired state is
not observable; both kernels return the same iteration count. The TypeLisp
recurrence is written inline in `mandelbrot-row`, matching ISPC's `static
inline` helper and keeping helper-call ABI cost out of the loop comparison.

Eight fixed cases cover zero width, zero height, immediate escape, never
escape, sub-gang width 3, exact width 16, tail width 19, and zero maximum
iterations. Both drivers compare every output element, a sentinel immediately
after the logical buffer, and a fixed weighted checksum. The width-sized
scratch arrays make the width-19 case an inactive-tail bounds check as well as
a value check.

TypeLisp scalar and AVX-512 are required. AVX2 records the exact staged
varying-while diagnostic owned by #4971. Real ISPC v1.31.0 validation is
optional because ISPC is not a project dependency.

Run the required TypeLisp checks and optional pinned-ISPC comparisons with:

```sh
scripts/verify-ispc-mandelbrot.sh
ISPC_BIN=/path/to/ispc scripts/verify-ispc-mandelbrot.sh
ISPC_BIN=/path/to/ispc ISPC_MANDELBROT_AVX512=1 scripts/verify-ispc-mandelbrot.sh
```

The verifier writes `target/ispc-mandelbrot-verify/static.tsv`. Each compiled
kernel row records its extracted symbol-body hash and byte size, instruction,
mask, branch, call, and vector-instruction counts, unique register count,
stack accesses, stack moves (a conservative spill/prologue proxy), and whether
the Mandelbrot helper remains inlined. Generic ISPC x4 is validation only, not
a scalar width match. AVX-512 execution is gated on F+BW+DQ host support.
