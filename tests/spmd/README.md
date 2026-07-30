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

Masked varying `if`/`while`/`match` fixtures and gather-only reads intentionally
compile and run in `avx2` and `avx512`.

- `tail_i64_add.tl` — `foreach` add over `n = 13` (not a multiple of the i64
  vector width 4/8): forces a masked/scalar tail. Exit 247.
- `tail_i32_add.tl` — `foreach` add over `n = 7` `i32` lanes (below the i32
  width 8/16): all-tail, a different element width. Exit 91.
- `foreach_bound_extremes.tl` - vectorizable zero-trip ranges with negative and
  near-`INT64_MAX` endpoints exercise the hoisted vector-start overflow clamps;
  a final eight-element range proves a full SIMD gang still runs. Exit 42.
- `uniform_zip_i64.tl` - `foreach` zip over `n = 13` i64 lanes with
  `a[i] * b[i] + c[i] + r`: exercises vector multiply, a third array operand,
  uniform scalar broadcast, and tail handling.
- `multi_output_i64.tl` - one straight-line `foreach` writes two distinct i64
  destinations while sharing `a[i] * 2`; covers empty, sub-gang, exact AVX2 and
  AVX-512 gangs, tails, ordered stores, common-subexpression reuse, and output
  sentinels. Exit 42.
- `store_alias_i64.tl` - a 257-element map receives one array as both inputs and
  output, exercising long unrolled gangs, runtime-alias load/store ordering,
  and the scalar tail. Exit 42.
- `multi_output_bounds_trap.tl` - a fused two-output map whose second
  destination is too short. The harness requires the ordinary bounds trap in
  scalar and every runnable SIMD mode, pinning all-destination safety checks.
- `vector_slice_surface_i64.tl` - `foreach` maps whose public functions take
  generated vectors and generated full slices, then borrow backing storage
  before the SPMD body. This pins the array-surface migration away from public
  `(Array T)` signatures.
- `inline_helper_i64.tl` - `foreach` over `n = 1` i64 lane through a direct
  source-known helper with a varying scalar argument. Exit 42.
- `inline_helper_shadow_i64.tl` - `foreach` over `n = 13` i64 lanes through a
  helper whose local binding would capture a naively substituted argument. Exit
  42 in scalar mode; SIMD modes reject this non-map helper-local `let` shape.
- `inline_helper_f64.tl` - `foreach` over `n = 13` f64 lanes through a direct
  source-known helper with a varying floating-point argument and result. Exit
  42.
- `private_helper_i64.tl` - scalar/AVX2/AVX-512 out-of-line helper ABI
  coverage for nested direct calls with varying i64 arguments/results and a
  masked tail. Exit 42.
- `private_helper_f64.tl` - scalar/AVX2/AVX-512 out-of-line helper ABI coverage
  for varying f64 arguments/results loaded and stored through a tail. Exit 42.
- `private_helper_bool.tl` - scalar/AVX2/AVX-512 out-of-line helper ABI coverage
  for a varying bool result consumed as a branch mask. Exit 42.
- `private_helper_masked_load.tl` - scalar/AVX2/AVX-512 private helper with a
  direct array load and bounds checks under composed branch/tail masks. Exit
  42.
- `private_helper_store.tl` - scalar/AVX2/AVX-512 private unit helper with a
  direct store under composed branch/tail masks. Exit 42.
- `private_helper_effects.tl` - scalar/AVX2/AVX-512 private unit helper with a
  store and atomic update under composed branch/tail masks. SIMD atomic bodies
  use the specified scalar fallback. Exit 42.
- `package_callable/` and `package_consumer/` - separately built producer and
  consumer packages for TLCI-described private SPMD calls. The consumer covers
  scalar and AVX-512 varying, mask, uniform, and unit results; i64/f64/f32
  arguments; nested masks; index forwarding; and a non-full tail. Exit 42.
- `masked_if_i64.tl` - AVX2/AVX-512 masked varying `if` over `n = 13` i64
  lanes, with direct-index predicated reads/writes and a masked tail. Exit 42.
- `masked_if_offset_i64.tl` - AVX2/AVX-512 masked varying `if` over `n = 12`
  i64 lanes with shifted contiguous `(+ i 1)` predicated reads/writes. Exit 42.
- `masked_if_index_value_i64.tl` - AVX2/AVX-512 masked varying `if` over
  `n = 13` i64 lanes whose condition and stores use the foreach index as a
  varying value. Exit 42.
- `masked_if_index_mod_i64.tl` - AVX2/AVX-512 masked varying `if` over
  `n = 13` i64 lanes whose condition uses `% i 2` lane-index arithmetic.
  Exit 42.
- `masked_if_value_i64.tl` - AVX2/AVX-512 value-producing masked `if` over
  `n = 13` i64 lanes feeding a predicated store. Exit 42.
- `masked_if_bitand_value_i64.tl` - AVX2/AVX-512 value-producing masked `if`
  over `n = 13` i64 lanes with a bit-and parity condition and add/sub branch
  values. Exit 42.
- `masked_if_bitwise_value_types.tl` - scalar/AVX2/AVX-512 nested,
  value-producing masked control flow using `bit-or` and `bit-xor` over every
  signed and unsigned integer lane width, with contextually typed leading
  literals, varying match arms, and non-full tails. Exit 42.
- `masked_if_shift_value_types.tl` - scalar/AVX2/AVX-512 masked `shl`/`shr`
  over i32/u32/i64/u64 values with varying counts, signed/logical right
  shifts, nested value branches, boundary counts, and non-full tails. Exit 42.
- `masked_if_shift_inactive.tl` - invalid i32 counts in inactive branch lanes
  and the backing slots beyond a non-full tail; only active valid lanes shift.
  Exit 42.
- `masked_if_shift_negative_trap.tl` and
  `masked_if_shift_large_trap.tl` - active negative i64 and width-equal u32
  counts take `tl_shift_abort` with exit 129 in every runnable mode.
- `masked_if_shift_i16_reject.tl` - scalar reference execution plus stable
  AVX2/AVX-512 operator/type/backend diagnostics for the deferred narrow-lane
  shift surface.
- `masked_if_value_types.tl` - AVX2/AVX-512 value-producing masked `if` over
  u32, u64, f32, f64, and bool lane results, each with a non-full tail. Exit
  42.
- `masked_move_fault_suppression.tl` - Linux scalar/AVX2/AVX-512 masked i64
  copy whose inactive lanes address an explicitly unmapped guard page, proving
  inactive masked loads and stores do not fault. Other hosts use a no-op parity
  case. Exit 42.
- `masked_if_nested_i64.tl` - AVX2/AVX-512 nested masked varying `if` over
  `n = 13` i64 lanes, covering parent/child branch-mask composition and a
  masked tail. Exit 42.
- `masked_if_i16_u16.tl` - AVX2/AVX-512 masked varying `if` over i16 and u16
  lanes, including signed and unsigned comparisons. Exit 42.
- `inline_helper_masked_if_i64.tl` - AVX2/AVX-512 masked varying `if` whose
  condition calls a direct helper returning a varying bool and whose taken
  branch calls a direct source-known helper with a varying scalar argument.
  Exit 42.
- `masked_if_match_i64.tl` - AVX2/AVX-512 varying `match` nested inside a
  masked varying `if` branch, covering branch-mask composition with match arm
  masks. Exit 42.
- `varying_while_i64.tl` - AVX2/AVX-512 varying `while` over `n = 13` i64
  lanes, covering per-lane loop convergence and a masked tail. Exit 42.
- `varying_while_f32_i32.tl` - AVX2/AVX-512 varying `while` over `n = 19`
  f32/i32 lanes, covering masked subtraction/multiplication, divergent
  iteration counts, and a masked tail. Exit 42.
- `masked_if_varying_while_i64.tl` - AVX2/AVX-512 varying `while` nested under
  a masked varying `if`, covering parent branch masks plus loop-carried masks.
  Exit 42.
- `varying_match_i64.tl` - AVX2/AVX-512 value-producing varying `match` over
  scalar i64 literal patterns, wildcard fallback, and catch-all lane binding.
  Exit 42.
- `varying_match_enum_payload.tl` - scalar/AVX2/AVX-512 varying `match` over
  enum tag arms and supported i64 payload bindings, including mixed arms and a
  tail. Exit 42.
- `varying_match_enum_helper_reject.tl` - scalar reference for an enum value
  returned by a helper; AVX2/AVX-512 must diagnose this non-contiguous varying
  enum source instead of silently scalarizing. Scalar exits 42.
- `i8_mul_reject.tl` - scalar `foreach` byte multiplication fixture that
  compiles and exits 42 in scalar mode; explicit SIMD modes reject it with the
  documented 8-bit lane multiplication diagnostic.
- `../integration/spmd_foreach.tl` - `foreach` add/sub maps over i64, u64,
  i32, u32, i16, u16, i8, u8, f64, and f32 arrays, plus bit-or/bit-xor over
  every integer width and multiplication where supported, self-checked against
  scalar loops across empty, sub-lane, exact-lane, and tail lengths. Exit 42.
- `map_shift_value_types.tl` - direct contiguous `shl`/`shr` maps over
  i32/u32/i64/u64 values with varying counts, signed/logical right shifts,
  full gangs, and partial tails whose inactive backing counts are invalid.
  `map_shift_{negative,large}_trap.tl` pin active-count exit 129 behavior, and
  `map_shift_i16_reject.tl` pins the narrow-lane operator/type diagnostic.
- `map_compare_surface.tl` - direct maps for all six comparison predicates
  plus unsigned and f32/f64 comparison lanes, producing bool-array masks.
  Scalar, AVX2, and AVX-512 modes exit 42.
- `../integration/spmd_gather_read.tl` - scalar/AVX2/AVX-512 `foreach`
  gather-read fixture that reads `xs[ix[i]]` into contiguous `out[i]` across
  empty, sub-lane, tail, and repeated-index lengths for i32, i64, f32, and f64.
  All modes exit 42; full SIMD gangs use native gathers and tails retain
  active-lane-only scalar checks.
- `bool_lanes.tl` - scalar/AVX2/AVX-512 bool dynamic-array lane fixture
  covering bool array copies and i64/i32/i16/i8 comparison results stored to
  bool arrays across empty, sub-lane, exact-lane, and tail lengths. All modes
  exit 42.
- `../integration/spmd_reduce_scalar.tl` — `spmd-reduce` `sum`/`max`/`min` over
  i64/i32/f64, f32 `sum`, plus direct bool-array `all`/`any` reductions across
  empty, sub-lane, AVX2/AVX-512 lane boundaries, tails, seeded folds,
  signed-zero, and finite-overflow cases. Exit 42. SIMD assembly gates pin the
  AVX2 i64 compare/blend expansion and native AVX2/AVX-512 bool mask
  reductions.
- `map_fused_reduce_i64.tl` - i64 `sum` over mapped add, sub/bit-or/bit-xor,
  and checked shift values, including empty, sub-gang, exact-gang, and tail
  ranges plus a neutral lane-index term. All modes exit 42; SIMD assembly gates
  require native mapped operators feeding a vector-resident accumulator and a
  single post-loop horizontal reduction.
- `../integration/spmd_scan_scalar.tl` - `spmd-scan` inclusive prefixes for
  i64 sum/min/max, i32 sum/min/max, and bool all/any across empty, sub-lane,
  exact-lane, multiple-gang, and tail lengths. Scalar and AVX2 execute the
  same result; AVX2 opcode gates require real shift/permute prefix stages.
  AVX-512 currently retains the scalar reference. Exit 42.
- `../integration/spmd_scan_{negative_start,short_output}_trap.tl` - active
  negative-start and post-gang short-destination bounds traps checked in every
  runnable backend mode by `scripts/verify-spmd-simd.sh`.
- `../../benchmarks/ispc/perfbench_gathers/bench.tl` - f32 `spmd-reduce`
  over lane-varying gathers with distinct and repeated offsets across empty,
  sub-lane, exact-lane, and tail lengths. All modes exit 42; SIMD modes use
  native gathers plus horizontal vector reduction.
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
  `uniform_zip_i64.tl`. Direct sub/bit-or/bit-xor opcode coverage lives in
  `../integration/spmd_foreach.tl`; direct checked shifts and comparisons live
  in `map_shift_value_types.tl` and `map_compare_surface.tl`. The intentionally
  unsupported byte multiply and narrow-shift policies are covered by
  `i8_mul_reject.tl` and `map_shift_i16_reject.tl`.
- Vector/slice public-surface coverage for borrowed backing storage lives in
  `vector_slice_surface_i64.tl`.
- Scalar and AVX2/AVX-512 gather-read coverage for dynamic arrays lives in
  `../integration/spmd_gather_read.tl`.
- Scalar and AVX2/AVX-512 bool dynamic-array lane coverage lives in
  `bool_lanes.tl`, including all AVX2 mask widths.
- AVX2/AVX-512 masked varying `if` direct-index, shifted-contiguous-index,
  foreach-index-as-value, value-producing i64 select, nested branch-mask
  composition, and i16/u16 coverage lives in `masked_if_i64.tl`,
  `masked_if_offset_i64.tl`, `masked_if_index_value_i64.tl`,
  `masked_if_index_mod_i64.tl`, `masked_if_value_i64.tl`,
  `masked_if_bitand_value_i64.tl`, `masked_if_bitwise_value_types.tl`,
  `masked_if_shift_value_types.tl`, `masked_if_shift_inactive.tl`,
  `masked_if_value_types.tl`, `masked_if_nested_i64.tl`, and
  `masked_if_i16_u16.tl`. The bitwise fixture covers `bit-or`/`bit-xor` IR
  and native opcode shapes for all eight contiguous integer lane types. The
  shift fixtures cover native dword/qword shift opcodes, the AVX2 signed-i64
  expansion, reduced active-lane trap guards, inactive branch/tail counts,
  and staged narrow-lane diagnostics.
- AVX2/AVX-512 scalar-lane varying `match` coverage lives in
  `varying_match_i64.tl` and `masked_if_match_i64.tl`; enum tag/payload
  varying-match coverage lives in `varying_match_enum_payload.tl` through the
  AVX2/AVX-512 masked-gang lowering and scalar reference path.
- AVX2/AVX-512 varying `while` coverage lives in `varying_while_i64.tl`,
  `varying_while_f32_i32.tl`, `masked_if_varying_while_i64.tl`, and
  `varying_while_nested_i64.tl`. The nested fixture covers zero, sub-gang,
  exact-gang, and tail lengths with exact-sized arrays, so inactive lanes must
  not perform invalid loads, stores, or bounds checks.
- Direct inline-helper coverage for varying scalar lane values lives in
  `inline_helper_i64.tl`, `inline_helper_shadow_i64.tl`,
  `inline_helper_f64.tl`, and `inline_helper_masked_if_i64.tl`. The
  `private_helper_*` fixtures execute the scalar and AVX-512 private ABI for
  i64/f64/bool values, nested calls, direct helper loads/bounds checks, branch
  masks, and tails. Focused source-to-private-call IR coverage also lives in
  `src/tests/compiler_spmd_call_lower_*_smoke.tl`. Function-value/indirect
  varying calls remain rejected by the safety fixtures.
- `spmd-reduce` and `spmd-scan` coverage for the documented
  operator/type surface lives in `../integration/spmd_reduce_scalar.tl` and
  `../integration/spmd_scan_scalar.tl`. `map_fused_reduce_i64.tl` covers
  contiguous array reads combined with uniform/lane terms and mapped
  sub/bitwise/checked-shift operators. The former also executes f32 sums; the
  latter requires native AVX2 prefixes for canonical contiguous shapes and
  scalar reference lowering elsewhere through `scripts/verify-spmd-simd.sh`.
- `spmd-broadcast` executable coverage lives in the `broadcast_lane*_{i64,u64,u32}.tl`
  fixtures, with mode-specific expectations in `scripts/verify-spmd-broadcast.sh`.
- `spmd-shuffle` scalar and native AVX2/AVX-512 coverage lives in
  `../integration/spmd_shuffle_{scalar,simd,types,reduce}.tl`. The SIMD fixtures
  cover identity, reverse, rotate, repeated/uniform selectors, all six numeric
  value types, bit-preserving float permutations, full gangs, and tails.
  `spmd_shuffle_tail_selector.tl` proves inactive lanes do not load operands;
  the `spmd_shuffle_*trap.tl` fixtures pin negative, out-of-range, and inactive
  tail selectors to the standard bounds abort. Opcode gates live in
  `scripts/verify-spmd-simd.sh`.
- `program-index`/`program-count` executable coverage lives in
  `lane_identity_i64.tl` and `lane_identity_reduce_i64.tl`, with mode-specific
  expectations in `scripts/verify-spmd-lane-identity.sh`; scalar same-exit
  coverage is covered by `../integration/spmd_lane_identity_scalar.tl`.
- SIMD reduction vectorization shape checks live in `src/compiler_lower.tl`
  and `src/compiler_backend_tests.tl`; this corpus runs the executable
  scalar/SIMD comparison for the same reduction fixture.
- Unsupported SPMD diagnostics are covered by `tests/safety/manifest.txt`,
  including outer mutation, unsupported f32/f64 min reductions, unsupported
  floating-point scans, nested scan bodies, and function-value/indirect varying
  calls that are outside the v1 private out-of-line call ABI.
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
on the aggregate `avx512` detector token, which requires F+BW+DQ and OS
ZMM/opmask state because the backend may emit byte-lane BW instructions and DQ
`vpmullq`. **AVX-512 only runs on the fleet's AVX-512 Windows box** (the only
AVX-512 machine): from Git Bash / MSYS with `clang` on `PATH`, both scripts
exercise AVX-512 there. Linux and
`windows-latest` CI run the best variant available on those hosts.

To make a new SPMD reference program (e.g. for #1011/#1012/#1013/#1014)
Windows-verifiable, add it here and to the `spmd_corpus` list in
`scripts/verify-spmd-simd.sh`.
