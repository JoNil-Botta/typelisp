# TypeLisp / ISPC comparison corpus

This opt-in corpus contains focused TypeLisp ports of kernels from ISPC's
official examples. It is separate from the required `benchmarks/` C comparison
gate: ISPC is not a project dependency, and a missing ISPC binary must never
skip TypeLisp's required correctness tests.

The corpus is pinned to ISPC v1.31.0, commit
`c6adb4f86f5678ce6c41951b1e2b59f727455697`. Derived sources retain their
BSD-3-Clause attribution and record the exact upstream path, function, and
adaptations. `case.tsv` has one row per TypeLisp backend mode so unsupported
pairs carry the exact compiler diagnostic instead of a zero or fabricated
measurement. Run the shared discovery, compilation, and static-analysis
harness with:

```sh
# TypeLisp-only correctness and static rows; ISPC rows say tool-missing.
scripts/measure-ispc-spmd.sh

# Full pinned comparison (the binary must identify itself as v1.31.0).
ISPC_BIN=/path/to/ispc scripts/measure-ispc-spmd.sh

# Fast parser/analyzer/report mutation tests.
scripts/measure-ispc-spmd.sh --self-test
```

The harness writes `support.tsv`, `static.tsv`, `comparison.tsv`, and
`tools.tsv` below `target/ispc-spmd-report/`, with assemblies and tool logs
under its `raw/` directory. `support.tsv` distinguishes declared support from
observed `measured`, `unsupported`, and `tool-missing` states. `static.tsv`
contains only extracted kernel-symbol bodies and reports their source hash and
bytes, instruction/branch/call/spill counts, distinct GPR/vector/opmask
registers, XMM/YMM/ZMM instruction census, gathers, scatters, and stack
accesses. `comparison.tsv` pairs measured TypeLisp/ISPC rows and computes metric
ratios and geomeans over positive measured pairs only. It never substitutes a
zero for a missing or unsupported implementation.

`tools.tsv` fingerprints the compiler binaries and exact flags. Reports are
informational: there is no checked performance baseline or tolerance. The
host-keyed retired-instruction tools currently accept the checked TypeLisp/C
SPMD corpus rather than arbitrary ISPC binaries, so this harness does not
mislabel those counters as ISPC comparisons.

ISPC v1.31.0 has no width-1 CPU target (`generic-i32x4` is the smallest
generic target). A TypeLisp scalar row therefore uses the checked C scalar
oracle for semantics and records the ISPC side as unsupported; generic-x4 may
validate the derived ISPC kernel but is not a width-matched scalar codegen
comparison. AVX2 `i32x8` and AVX-512 `x16` remain width-matched for f32 lanes.

## Cases

| Case | Lane type | Upstream kernel | Current TypeLisp status |
| --- | --- | --- | --- |
| [`perfbench_gathers`](perfbench_gathers/) | `f32` | `examples/cpu/perfbench/perfbench.ispc::gathers` | Scalar, AVX2, and AVX-512 supported |
| [`perfbench_loads`](perfbench_loads/) | `f32` | `examples/cpu/perfbench/perfbench.ispc::loads` | Scalar, AVX2, and AVX-512 supported |
| [`perfbench_stores`](perfbench_stores/) | `f32` | `examples/cpu/perfbench/perfbench.ispc::stores` | Supported |
| [`mandelbrot`](mandelbrot/) | `f32`/`i32` | `examples/cpu/mandelbrot/mandelbrot.ispc::mandelbrot_ispc` | Scalar and AVX-512 supported; AVX2 staged by #4971 |
| [`point_transform`](point_transform/) | `f32` | `examples/cpu/point_transform_ctypes/point_transform.ispc::transform_points` | Scalar, AVX2, and AVX-512 supported |

`perfbench_loads` uses only integer-valued binary32 inputs and keeps every
partial sum within the exactly representable integer range. Its scalar oracle,
ISPC horizontal reduction, and TypeLisp reduction therefore agree
bit-for-bit despite their different grouping. Grouping differences are semantic
metadata, not codegen regressions, for these exact cases.

The checked cases are empty (`+0`, `0x00000000`), sub-gang `1+2+3` (`6`,
`0x40c00000`), exact gangs of 8 and 16 ones (`0x41000000`, `0x41800000`),
a 19-element signed tail (`-5`, `0xc0a00000`), positive/negative cancellation
(`+0`, `0x00000000`), and 65,536 ones (`0x47800000`). Both drivers validate
these fixed result bytes, not just mutual agreement with an oracle.

`perfbench_stores` is backend-mode-observable: scalar, AVX2, and AVX-512 use
gang widths 1, 8, and 16 for f32. Its distinct integer-valued lane inputs make
the complete output byte pattern repeat at exactly that width. The TypeLisp
and width-matched ISPC rows must agree, while generic x4 is validation only.

`perfbench_gathers` preserves the upstream lane-specific offset selection as
`values[i + offsets[program-index]]`. SIMD modes issue checked `vgatherqps`;
scalar uses checked lane loads. Five backing elements cover active offsets 0
through 4 while leaving incorrectly active tail lanes out of range.

`point_transform` factors the upstream uniform `sin(rotation)`/`cos(rotation)`
prelude out of both implementations and passes identical exact f32 constants.
It preserves the scale/rotate/translate/strength zip body without adding a
libm dependency or measuring a struct ABI. Exact identity-rotation fixtures and
a finite-only two-ULP oracle cover empty, x8/x16, sub-gang, and tail lengths.

Validate the required metadata/diagnostic contract, and optionally the real
ISPC generic/AVX2 driver when v1.31.0 is installed, with:

```sh
scripts/verify-ispc-perfbench-gathers.sh
ISPC_BIN=/path/to/ispc scripts/verify-ispc-perfbench-gathers.sh
scripts/verify-ispc-perfbench-loads.sh
ISPC_BIN=/path/to/ispc scripts/verify-ispc-perfbench-loads.sh
scripts/verify-ispc-perfbench-stores.sh
ISPC_BIN=/path/to/ispc scripts/verify-ispc-perfbench-stores.sh
scripts/verify-ispc-mandelbrot.sh
ISPC_BIN=/path/to/ispc scripts/verify-ispc-mandelbrot.sh
scripts/verify-ispc-point-transform.sh
ISPC_BIN=/path/to/ispc scripts/verify-ispc-point-transform.sh
```

## Case contract

Every immediate child directory is discovered when it contains `case.tsv`.
It must also contain `bench.tl`, `kernel.ispc`, `driver.c`, and
`LICENSE.BSD-3-Clause`. Metadata uses the exact 23-column
`typelisp-ispc-case-v1` header checked into the existing cases and must contain
exactly one `scalar`, `avx2`, and `avx512` row. Each row records both exported
symbols, lane/argument/repetition data, expected exit status, and pinned
upstream provenance. The f32 width mapping is fixed: scalar/1 has no ISPC
target, AVX2/8 uses `avx2-i32x8`, and AVX-512/16 uses `avx512skx-x16`.

A corresponding `scripts/verify-ispc-<case-with-hyphens>.sh` remains the
semantic authority. The shared harness runs it before measurement, so exit,
stdout, stderr, case-specific bytes, and tolerance checks must pass before any
static comparison is emitted.
