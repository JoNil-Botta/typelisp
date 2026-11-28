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

- `scripts/verify-spmd-simd.sh` batches `corpus.d/*.manifest` at O0, O1 and O2
  in scalar, SSE2, AVX2 and AVX-512 on Linux and Windows. Each executable must
  exit like the same program's O1 scalar reference and leave stderr empty.
  Expected compiler diagnostics are checked individually at every applicable
  level. The gate also runs `simd.d` for assembly shapes, ISA guards and traps.
- `gang-width.cases` (run by `scripts/verify-codegen-cases.sh`) pins the
  programs whose result intentionally observes the gang width:
  `broadcast_lane*` (`spmd-broadcast`) and `lane_identity_*`
  (`program-index`/`program-count`).
- `scripts/verify-spmd-runtime-dispatch.sh` checks that a `defdispatch`
  binary selects AVX-512, AVX2 or scalar from the host's capabilities.
- `scripts/verify-spmd-package-calls.sh` builds `package_callable/` and
  `package_consumer/` as separate packages and checks the TLCI-described
  private SPMD calls between them.
- Unsupported SPMD shapes are diagnostics in `tests/safety/manifest.d/*.manifest`;
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
scripts/ci-verify.sh --gates stage2-spmd-simd-comparison
TYPELISP_BIN=./target/stage0/typelisp scripts/verify-spmd-simd.sh
TYPELISP_BIN=./target/stage0/typelisp scripts/verify-codegen-cases.sh tests/spmd/gang-width.cases
TYPELISP_BIN=./target/stage0/typelisp scripts/verify-spmd-runtime-dispatch.sh
```

The comparison gate uses the matching prebuilt `stdlib.tli` and `libstdlib.a`
beside the compiler, in its parent directory, or under `TYPELISP_SYSROOT`.
Each matrix cell compiles in one batch with a 120-second deadline. Individual
diagnostic compiles, assembly, links and executions have a 30-second deadline.
`TYPELISP_SPMD_SIMD_BATCH_SECONDS` and `TYPELISP_SPMD_SIMD_STEP_SECONDS` set
the deadlines for local investigations. A watchdog timeout fails its row even
if the watchdog's status equals the scalar reference.

`scripts/detect-simd-isa.sh` checks CPUID and OS state for AVX2 and AVX-512.
AVX-512 requires F, BW and DQ or the configured Intel SDE route. A mode with
no execution route still compiles at every level and reports why it could
not run. CI requires an AVX-512 execution route. The two existing SSE2
compile-only gather fixtures compare lane IDs across loops that intentionally
use different widths in SSE2. The forced-SDE gate repeats AVX-512 at all
three levels against the ordinary gate's O1 scalar receipts.

Add same-exit programs in a new `corpus.d/<feature>.manifest`, with one
repository-relative source path per line. Put gang-width-dependent exit checks
in `gang-width.cases` and assembly or trap checks in a `simd.d` fragment.
The `foreach-active` corpus runs in all four modes. Its `simd.d` cases also
check lane visitation order, effects before the first fault, and native code shape.
