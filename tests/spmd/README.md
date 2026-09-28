# SPMD corpus

Programs whose exit code is computed by SIMD-lowered `foreach`, masked control
flow, `spmd-reduce`/`spmd-scan` or private SPMD helper calls, so a wrong SIMD
result (especially in a tail) changes it. Each fixture's header comment says
what it exercises and what it returns.

These low-level fixtures use the private `(__tl_dyn-array T)` representation
for their backing buffers: they exercise bounds checks and SIMD lowering
directly. Public-surface coverage uses native `Slice`/`Vec` values
(`native_slice_*.tl` and the `spmd_*` integration fixtures).

## Checks

- `scripts/verify-spmd-simd.sh` builds its `spmd_corpus` list at `scalar`,
  `avx2` and `avx512` and requires every runnable SIMD mode to exit like the
  `scalar` reference (or to fail with the pinned diagnostic), then runs
  `simd.cases`: the per-program assembly shapes and the trap-path programs.
- `gang-width.cases` (run by `scripts/verify-codegen-cases.sh`) pins the
  programs whose result intentionally observes the gang width:
  `broadcast_lane*` (`spmd-broadcast`) and `lane_identity_*`
  (`program-index`/`program-count`).
- `scripts/verify-spmd-runtime-dispatch.sh` checks that a `defdispatch`
  binary selects AVX-512, AVX2 or scalar from the host's capabilities.
- `scripts/verify-spmd-package-calls.sh` builds `package_callable/` and
  `package_consumer/` as separate packages and checks the TLCI-described
  private SPMD calls between them.
- Unsupported SPMD shapes are diagnostics in `tests/safety/manifest.txt`;
  compiler-internal lowering and private-call ABI tests are the
  `src/tests/compiler_spmd_*_smoke.tl` drivers.

Fixture families: `tail_*`, `*_fault_suppression` and `foreach_bound_extremes`
(tails and inactive lanes), `masked_if_*`, `varying_while_*`, `varying_match_*`
and `full_gang_all_active_i64` (masked control flow), `*_shift_*`, `byte_mul_*`
and `map_compare_surface` (per-type opcodes and checked traps),
`inline_helper_*` and `private_helper_*` (helper inlining and the private call
ABI), `multi_output_*`, `store_alias_i64` and `uniform_zip_i64` (map shapes),
`map_fused_reduce_i64` and `bool_lanes` (reductions and bool lanes).

## Running

```sh
TYPELISP_BIN=./target/stage0/typelisp scripts/verify-spmd-simd.sh
TYPELISP_BIN=./target/stage0/typelisp scripts/verify-codegen-cases.sh tests/spmd/gang-width.cases
TYPELISP_BIN=./target/stage0/typelisp scripts/verify-spmd-runtime-dispatch.sh
```

SIMD execution is gated by `scripts/detect-simd-isa.sh` (CPUID plus OS state,
not the host OS); AVX-512 requires the aggregate `avx512` token (F+BW+DQ).
Programs are not run in a mode the host cannot execute.
To add a same-exit program, add it to `spmd_corpus` in
`scripts/verify-spmd-simd.sh`; a program whose exit depends on the gang width
belongs in `gang-width.cases`, and an assembly-shape or trap check in
`simd.cases`.
