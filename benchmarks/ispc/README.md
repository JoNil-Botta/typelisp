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
measurement. The shared discovery, compilation, static-analysis, and optional
retired-instruction reporting contract is tracked by #4968.

ISPC v1.31.0 has no width-1 CPU target (`generic-i32x4` is the smallest
generic target). A TypeLisp scalar row therefore uses the checked C scalar
oracle for semantics and records the ISPC side as unsupported; generic-x4 may
validate the derived ISPC kernel but is not a width-matched scalar codegen
comparison. AVX2 `i32x8` and AVX-512 `x16` remain width-matched for f32 lanes.

## Cases

| Case | Lane type | Upstream kernel | Current TypeLisp status |
| --- | --- | --- | --- |
| [`perfbench_loads`](perfbench_loads/) | `f32` | `examples/cpu/perfbench/perfbench.ispc::loads` | Scalar, AVX2, and AVX-512 supported |

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

Validate the required metadata/diagnostic contract, and optionally the real
ISPC generic/AVX2 driver when v1.31.0 is installed, with:

```sh
scripts/verify-ispc-perfbench-loads.sh
ISPC_BIN=/path/to/ispc scripts/verify-ispc-perfbench-loads.sh
```
