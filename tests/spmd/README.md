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

Masked varying `if` fixtures intentionally compile and run in `avx512`, while
`avx2` compile is expected to fail with an explicit staged diagnostic instead of
falling back to scalar code.

- `tail_i64_add.tl` — `foreach` add over `n = 13` (not a multiple of the i64
  vector width 4/8): forces a masked/scalar tail. Exit 247.
- `tail_i32_add.tl` — `foreach` add over `n = 7` `i32` lanes (below the i32
  width 8/16): all-tail, a different element width. Exit 91.
- `uniform_zip_i64.tl` - `foreach` zip over `n = 13` i64 lanes with
  `a[i] * b[i] + c[i] + r`: exercises vector multiply, a third array operand,
  uniform scalar broadcast, and tail handling.
- `inline_helper_i64.tl` - `foreach` over `n = 1` i64 lane through a direct
  source-known helper with a varying scalar argument. Exit 42.
- `inline_helper_shadow_i64.tl` - `foreach` over `n = 13` i64 lanes through a
  helper whose local binding would capture a naively substituted argument. Exit
  42 in scalar mode; SIMD modes reject this non-map helper-local `let` shape.
- `inline_helper_f64.tl` - `foreach` over `n = 13` f64 lanes through a direct
  source-known helper with a varying floating-point argument and result. Exit
  42.
- `masked_if_i64.tl` — AVX-512-only masked varying `if` over `n = 13` i64
  lanes, with direct-index predicated reads/writes and a masked tail. Exit 42.
- `masked_if_offset_i64.tl` - AVX-512-only masked varying `if` over `n = 12`
  i64 lanes with shifted contiguous `(+ i 1)` predicated reads/writes. Exit 42.
- `masked_if_index_value_i64.tl` - AVX-512-only masked varying `if` over
  `n = 13` i64 lanes whose condition and stores use the foreach index as a
  varying value. Exit 42.
- `masked_if_index_mod_i64.tl` - AVX-512-only masked varying `if` over
  `n = 13` i64 lanes whose condition uses `% i 2` lane-index arithmetic.
  Exit 42.
- `masked_if_value_i64.tl` - AVX-512-only value-producing masked `if` over
  `n = 13` i64 lanes feeding a predicated store. Exit 42.
- `masked_if_nested_i64.tl` - AVX-512-only nested masked varying `if` over
  `n = 13` i64 lanes, covering parent/child branch-mask composition and a
  masked tail. Exit 42.
- `masked_if_i16_u16.tl` - AVX-512-only masked varying `if` over i16 and u16
  lanes, including signed and unsigned comparisons. Exit 42.
- `inline_helper_masked_if_i64.tl` - AVX-512-only masked varying `if` whose
  condition calls a direct helper returning a varying bool and whose taken
  branch calls a direct source-known helper with a varying scalar argument.
  Exit 42.
- `i8_mul_reject.tl` - scalar `foreach` byte multiplication fixture that
  compiles and exits 42 in scalar mode; explicit SIMD modes reject it with the
  documented 8-bit lane multiplication diagnostic.
- `../integration/spmd_foreach.tl` - `foreach` add/mul maps over i64, u64,
  i32, u32, i16, u16, i8, u8, f64, and f32 arrays, self-checked against
  scalar loops across empty, sub-lane, exact-lane, and tail lengths. Exit 42.
- `../integration/spmd_gather_read.tl` - scalar `foreach` gather-read fixture
  that reads `xs[ix[i]]` into contiguous `out[i]` across empty, sub-lane, tail,
  and repeated-index lengths. Scalar exits 42; explicit SIMD modes report the
  staged non-contiguous-map diagnostic.
- `bool_lanes.tl` - AVX-512-only bool dynamic-array lane fixture covering
  bool array copies and i64 comparison results stored to bool arrays across
  empty, sub-lane, exact-lane, and tail lengths. Scalar exits 42; AVX2 reports
  the staged bool-lane diagnostic.
- `../integration/spmd_reduce_scalar.tl` — `spmd-reduce` `sum`/`max`/`min` over
  i64/i32/f64 plus `all`/`any` bool reductions across empty, sub-lane,
  exact-lane, and tail lengths. Exit 42.
- `../integration/spmd_scan_scalar.tl` - `spmd-scan` inclusive prefixes for
  i64 sum/min/max, i32 sum/min/max, and bool all/any across empty, sub-lane,
  exact-lane, and tail lengths. Exit 42.
- `runtime_dispatch_select.tl` — one `defdispatch` binary whose variants share
  the same i64 SPMD checksum and encode the selected variant in the exit code.
  Scalar exits 42, AVX2 exits 106, and AVX-512 exits 170.
- `broadcast_lane*_i64.tl`, `broadcast_lane*_u64.tl`, and
  `broadcast_lane*_u32.tl` are backend-observable `spmd-broadcast` fixtures
  checked by `scripts/verify-spmd-broadcast.sh`. They are intentionally
  separate from the scalar-vs-SIMD same-exit corpus.
- `lane_identity_i64.tl` and `lane_identity_reduce_i64.tl` are
  backend-observable `(program-index)`/`(program-count)` fixtures checked by
  `scripts/verify-spmd-lane-identity.sh`. They assert the scalar contract
  (`program-index = 0`, `program-count = 1`) and backend-specific SIMD lane/tail
  behavior from `SPEC.md` section 5.15 for `foreach` maps and `spmd-reduce`
  values.

Coverage map:

- `foreach` scalar and SIMD map/zip coverage for `i64`, `u64`, `i32`, `u32`,
  `i16`, `u16`, `i8`, `u8`, `f64`, and `f32` lives in
  `../integration/spmd_foreach.tl`, the two tail fixtures, and
  `uniform_zip_i64.tl`. The intentionally unsupported byte multiply policy is
  covered by `i8_mul_reject.tl`.
- Scalar gather-read coverage for dynamic arrays lives in
  `../integration/spmd_gather_read.tl`; explicit SIMD modes keep a staged
  diagnostic until vector gather lowering is implemented.
- AVX-512 bool dynamic-array lane coverage lives in `bool_lanes.tl`; AVX2 keeps
  an explicit staged diagnostic for the same source shape.
- AVX-512 masked varying `if` direct-index, shifted-contiguous-index,
  foreach-index-as-value, value-producing i64 select, nested branch-mask
  composition, and i16/u16 coverage lives in `masked_if_i64.tl`,
  `masked_if_offset_i64.tl`, `masked_if_index_value_i64.tl`,
  `masked_if_index_mod_i64.tl`, `masked_if_value_i64.tl`,
  `masked_if_nested_i64.tl`, and `masked_if_i16_u16.tl`. Broader
  value-producing masked-if selects are tracked by #3356.
- Direct inline-helper coverage for varying scalar lane values lives in
  `inline_helper_i64.tl`, `inline_helper_shadow_i64.tl`,
  `inline_helper_f64.tl`, and `inline_helper_masked_if_i64.tl`.
- `spmd-reduce` and `spmd-scan` scalar coverage for the documented
  operator/type surface lives in `../integration/spmd_reduce_scalar.tl` and
  `../integration/spmd_scan_scalar.tl`.
- `spmd-broadcast` executable coverage lives in the `broadcast_lane*_{i64,u64,u32}.tl`
  fixtures, with mode-specific expectations in `scripts/verify-spmd-broadcast.sh`.
- `program-index`/`program-count` executable coverage lives in
  `lane_identity_i64.tl` and `lane_identity_reduce_i64.tl`, with mode-specific
  expectations in `scripts/verify-spmd-lane-identity.sh`; scalar same-exit
  coverage is covered by `../integration/spmd_lane_identity_scalar.tl`.
- SIMD reduction vectorization shape checks live in `src/compiler_lower.tl`
  and `src/compiler_backend_tests.tl`; this corpus runs the executable
  scalar/SIMD comparison for the same reduction fixture.
- Unsupported SPMD diagnostics are covered by `tests/safety/manifest.txt`,
  including outer mutation, unsupported `f64` min reduction, unsupported
  floating-point scans, nested scan bodies, and indirect calls with varying
  arguments.
## Running

```sh
# Uses the release compiler unless TYPELISP_BIN is set.
scripts/verify-spmd-simd.sh
scripts/verify-spmd-runtime-dispatch.sh
sh scripts/verify-spmd-broadcast.sh
sh scripts/verify-spmd-lane-identity.sh
TYPELISP_BIN=./target/stage0/typelisp scripts/verify-spmd-simd.sh
TYPELISP_BIN=./target/stage0/typelisp scripts/verify-spmd-runtime-dispatch.sh
TYPELISP_BIN=./target/stage0/typelisp sh scripts/verify-spmd-broadcast.sh
TYPELISP_BIN=./target/stage0/typelisp sh scripts/verify-spmd-lane-identity.sh
```

SIMD modes are gated by `scripts/detect-simd-isa.sh` (real CPUID capability, not
host OS), so explicit SIMD modes are skipped cleanly when their ISA is absent.
The runtime-dispatch harness never skips the dispatch path; it expects scalar,
AVX2, or AVX-512 based on the same capability probe. AVX-512 execution is gated
on the `avx512bw` detector token because byte-lane lowering uses BW
instructions. **AVX-512 only runs on the fleet's AVX-512 Windows box** (the only
AVX-512 machine): from Git Bash / MSYS with `clang` on `PATH`, both scripts
exercise AVX-512 there. Linux and
`windows-latest` CI run the best variant available on those hosts.

To make a new SPMD reference program (e.g. for #1011/#1012/#1013/#1014)
Windows-verifiable, add it here and to the `spmd_corpus` list in
`scripts/verify-spmd-simd.sh`.
