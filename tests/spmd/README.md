# SPMD scalar-vs-SIMD comparison corpus (#1149)

Programs whose exit code is computed by a SIMD-lowered `foreach` map or
`spmd-reduce` fold. `scripts/verify-spmd-simd.sh` builds each at `scalar`,
`avx2`, and `avx512` and asserts every runnable mode produces the **same** exit
code as the `scalar` reference — the comparison the SPMD acceptance criteria
(#1011–#1014) need, beyond #1148's single full-width program.

`SPEC.md` also defines the `defdispatch` declaration form for runtime SIMD
dispatch: one logical function lists scalar, AVX2, and AVX-512 variant
functions, and ordinary calls choose the best runnable variant once per process.
`scripts/verify-spmd-runtime-dispatch.sh` builds one dispatched binary and
checks that the runtime-selected variant is AVX-512 on AVX-512 hosts, AVX2 on
AVX2-only hosts, and scalar otherwise.

The corpus emphasizes the cases where SIMD bugs hide:

- `tail_i64_add.tl` — `foreach` add over `n = 13` (not a multiple of the i64
  vector width 4/8): forces a masked/scalar tail. Exit 247.
- `tail_i32_add.tl` — `foreach` add over `n = 7` `i32` lanes (below the i32
  width 8/16): all-tail, a different element width. Exit 91.
- `masked_if_i64.tl` — AVX-512-only masked varying `if` over `n = 13` i64
  lanes, with direct-index predicated reads/writes and a masked tail. Exit 42.
- `../integration/spmd_foreach.tl` — `foreach` add over i64, i32, f64, and
  f32 arrays, self-checked against scalar loops across empty, sub-lane,
  exact-lane, and tail lengths. Exit 42.
- `../integration/spmd_reduce_scalar.tl` — `spmd-reduce` `sum`/`max`/`min` over
  i64/i32/f64 plus `all`/`any` bool reductions across empty, sub-lane,
  exact-lane, and tail lengths. Exit 42.
- `runtime_dispatch_select.tl` — one `defdispatch` binary whose variants share
  the same i64 SPMD checksum and encode the selected variant in the exit code.
  Scalar exits 42, AVX2 exits 106, and AVX-512 exits 170.

Future `(program-index)`/`(program-count)` fixtures should be kept separate from
the scalar-vs-SIMD same-exit corpus when they intentionally observe backend gang
width. They should instead assert the scalar contract (`program-index = 0`,
`program-count = 1`) and backend-specific SIMD lane/tail behavior from
`SPEC.md` section 5.15.

Coverage map:

- `foreach` scalar and SIMD map/zip coverage for `i64`, `i32`, `f64`, and
  `f32` lives in `../integration/spmd_foreach.tl` and the two tail fixtures.
- AVX-512 masked varying `if` direct-index coverage lives in
  `masked_if_i64.tl`.
- `spmd-reduce` scalar coverage for the documented operator/type surface lives
  in `../integration/spmd_reduce_scalar.tl`.
- SIMD reduction vectorization shape checks live in `selfhost/compiler_lower.tl`
  and `selfhost/compiler_backend_tests.tl`; this corpus runs the executable
  scalar/SIMD comparison for the same reduction fixture.
- Unsupported SPMD diagnostics are covered by `tests/safety/manifest.txt`,
  including outer mutation, unsupported `f64` min reduction, and calls with
  varying arguments.
- Future lane identity diagnostics should cover use outside SPMD scope, use in
  `foreach` start/end or `spmd-reduce` start/end/init expressions, and nested
  SPMD scope behavior once nested SPMD is designed.

## Running

```sh
# Uses the release compiler unless TYPELISP_BIN is set.
scripts/verify-spmd-simd.sh
scripts/verify-spmd-runtime-dispatch.sh
TYPELISP_BIN=./target/stage0/typelisp scripts/verify-spmd-simd.sh
TYPELISP_BIN=./target/stage0/typelisp scripts/verify-spmd-runtime-dispatch.sh
```

SIMD modes are gated by `scripts/detect-simd-isa.sh` (real CPUID capability, not
host OS), so explicit SIMD modes are skipped cleanly when their ISA is absent.
The runtime-dispatch harness never skips the dispatch path; it expects scalar,
AVX2, or AVX-512 based on the same capability probe. **AVX-512 only runs on the
fleet's AVX-512 Windows box** (the only AVX-512 machine): from Git Bash / MSYS
with `clang` on `PATH`, both scripts exercise AVX-512 there. Linux and
`windows-latest` CI run the best variant available on those hosts.

To make a new SPMD reference program (e.g. for #1011/#1012/#1013/#1014)
Windows-verifiable, add it here and to the `spmd_corpus` list in
`scripts/verify-spmd-simd.sh`.
