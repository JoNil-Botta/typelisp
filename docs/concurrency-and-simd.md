# Concurrency and SIMD

This page describes safe task threads and SPMD/SIMD lowering. The formal rules
and supported subsets are in [SPEC.md](../SPEC.md).

## Safe task threading

Safe task threads use generated typed closure modules from
`stdlib/thread.tl` — for example `(import (thread.handle i64) as
thread-i64)` with `thread-i64.spawn` / `thread-i64.join` — plus aggregate
wrappers. `thread.spawn-i64-vec` / `thread.join-i64-vec` transfer one owned
generated `(vector i64)` result through a fresh spanning atomic arena. The
checker validates captured environments and joined results
structurally (no traits): references, borrowed views, scoped regions,
ordinary arenas, raw-pointer ownership claims, and live mutable aliases do
not cross task-thread boundaries; values cross threads only when owned by an
arena whose lifetime spans both, such as a shared atomic arena.
`stdlib/sync.tl` provides generated channel and mutex modules. An atomic
arena proves allocation lifetime, not data-race freedom — use mutexes,
channels, or atomics for shared mutation. See
[`../examples/safe_threading.tl`](../examples/safe_threading.tl) for a complete
safe program and [SPEC.md](../SPEC.md) section 6.5 for the model.

## SPMD and SIMD

Task threading creates independently scheduled workers; SPMD is
data-parallel lowering inside one task. `compile`, `run`, and `build` accept
`--backend-mode scalar|avx2|avx512` (default `scalar`).

- Every SPMD form has scalar reference lowering; backend modes must preserve
  its semantics.
- AVX2 and AVX-512 vectorize a contiguous `foreach` map/zip subset over
  `i8`–`i64`, `u8`–`u64`, `f32`, and `f64` lanes (AVX-512 additionally
  covers bool lanes), plus eligible `spmd-reduce` array folds (`sum` over
  `i32`/`i64`/`f32`/`f64`, `min`/`max` over `i32`/`i64`, and `all`/`any` over
  bool). Contiguous maps can borrow vector backing or slice storage, so public
  APIs can take vector/slice views.
- Scalar lowering supports `spmd-reduce` `sum`/`min`/`max`/`all`/`any` and
  inclusive `spmd-scan` over the SPEC-supported types. AVX2 and AVX-512
  additionally vectorize canonical contiguous range-wide scans for i32/i64
  `sum`/`min`/`max` and bool `all`/`any`, carrying the final prefix between
  full gangs and resuming with an in-order scalar tail.
- Masked varying `if` (including nested masks and value-producing selects),
  varying `while` with loop-carried active masks, and varying `match`
  (including AVX2/AVX-512 enum tags and scalar-lane payload bindings) run in the
  documented scalar, AVX2, and AVX-512 subsets. Unsupported early exits and
  other deferred control-flow shapes report explicit diagnostics instead of
  silently scalarizing.
- `(program-index)` and `(program-count)` are lane identity forms inside
  SPMD scopes; programs using them intentionally observe backend gang
  width.
- AVX2 and AVX-512 lower eligible numeric `spmd-shuffle` values/selectors to
  native dword/qword permutations. Ordered selector checks and gang-preserving
  tails retain the scalar bounds-trap contract.
- `defdispatch` declares one logical function with scalar/AVX2/AVX-512
  variants; ordinary calls resolve once per process via the CPUID/XGETBV
  checks exposed by `stdlib/cpu.tl` (AVX-512 dispatch requires F+BW+DQ and OS
  ZMM/opmask state).

Public vector/mask value types are deferred by design. Numeric `spmd-shuffle`
maps and reduction values have native AVX2/AVX-512 lowering.
Non-inlined varying helper calls within one program compile and run through the
private scalar/AVX2/AVX-512 ABI. Package imports support the scalar/AVX-512
private ABI when the dependency's TLCI v2 metadata advertises an exact matching
specialization in its runtime archive. See [SPEC.md](../SPEC.md) sections 5.15
and 8.
