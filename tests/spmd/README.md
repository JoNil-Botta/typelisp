# SPMD scalar-vs-SIMD comparison corpus (#1149)

Programs whose exit code is computed by a SIMD-lowered `foreach` map or
`spmd-reduce` fold. `scripts/verify-spmd-simd.sh` builds each at `scalar`,
`avx2`, and `avx512` and asserts every runnable mode produces the **same** exit
code as the `scalar` reference — the comparison the SPMD acceptance criteria
(#1011–#1014) need, beyond #1148's single full-width program.

`SPEC.md` also defines the future `defdispatch` declaration form for runtime
SIMD dispatch: one logical function lists scalar, AVX2, and AVX-512 variant
functions, and ordinary calls choose the best runnable variant once per process.
Until that parser/compiler support lands, this corpus keeps using explicit
`--backend-mode` builds to compare the same source under each backend mode.

The corpus emphasizes the cases where SIMD bugs hide:

- `tail_i64_add.tl` — `foreach` add over `n = 13` (not a multiple of the i64
  vector width 4/8): forces a masked/scalar tail. Exit 247.
- `tail_i32_add.tl` — `foreach` add over `n = 7` `i32` lanes (below the i32
  width 8/16): all-tail, a different element width. Exit 91.
- `../integration/spmd_foreach.tl` — `foreach` add over a full 64-element
  array for i64 and i32, self-checked against a scalar loop. Exit 42.
- `../integration/spmd_reduce_scalar.tl` — `spmd-reduce` `sum`/`max`/`min` over
  i64/i32/f64 across lengths including a non-divisible tail. Exit 42.

## Running

```sh
# Uses the release compiler unless TYPELISP_BIN is set.
scripts/verify-spmd-simd.sh
TYPELISP_BIN=./target/release/typelisp scripts/verify-spmd-simd.sh
```

SIMD modes are gated by `scripts/detect-simd-isa.sh` (real CPUID capability, not
host OS), so a mode is skipped cleanly when its ISA is absent. **AVX-512 only
runs on the fleet's AVX-512 Windows box** (the only AVX-512 machine): from Git
Bash / MSYS with `clang` on `PATH`, all of scalar/avx2/avx512 are exercised
there. Linux and `windows-latest` CI run scalar+avx2 and skip avx512.

To make a new SPMD reference program (e.g. for #1011/#1012/#1013/#1014)
Windows-verifiable, add it here and to the `spmd_corpus` list in
`scripts/verify-spmd-simd.sh`.
