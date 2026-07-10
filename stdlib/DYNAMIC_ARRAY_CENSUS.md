# Dynamic Array Migration Census

This census tracks unsized `(Array T)` uses while public `Array` moves toward
fixed-size-only `(Array T N)`. Update it when a migration changes the category
of a file or module.

## Public Growable Collections

These are the uses that should move to generated vectors or vector/slice-style
borrowed APIs.

- `stdlib/vector.tl`: public growable sequences use generated modules such as
  `(import stdlib.vector)` plus
  `(import (vector.vector i64) as ivec)`, whose reads take `&` and mutators take
  `&mut`.
- `stdlib/process.tl`, `stdlib/msvc.tl`, `stdlib/env.tl`, `stdlib/fs.tl`,
  `stdlib/random.tl`, CLI drivers, doc tooling, and LSP tooling use local
  generated `(vector T)` aliases for public or tool-facing growable sequences.
- `examples/lexer.tl` and `examples/calc.tl` now use generated token vectors
  instead of exposing token streams as public dynamic arrays.
- `examples/parser.tl` still uses small dynamic arrays as parser cursor and
  hand-built token fixtures. Those are not growable collection APIs; they can
  later become fixed arrays or a generated vector fixture when parser examples
  are refreshed.

## Intentional Backing Buffers

These unsized arrays should stay isolated until private-buffer or byte-buffer
surfaces replace them.

- Collection internals in `stdlib/vector.tl`, `stdlib/vector_slice.tl`,
  `stdlib/queue.tl`, `stdlib/hashmap.tl`,
  `stdlib/set.tl`, and `stdlib/text_buf*.tl`.
- Binary and byte storage in `stdlib/byte_buf.tl`, `stdlib/byte_buf_core.tl`,
  `stdlib/ffi.tl`,
  `stdlib/io.tl`, `stdlib/fs.tl`, `stdlib/process_runtime.tl`,
  `src/tlci_core.tl`, `src/compiler_object_elf.tl`,
  `src/compiler_object_coff.tl`, and object-byte paths in
  `src/compiler_backend.tl`.
- Compiler-internal scratch buffers, dense tables, captured-field lists, codegen
  byte streams, and serialized metadata in `src/*.tl`. These are not public
  source APIs and should move only when a private dynamic-buffer abstraction is
  available.
- Thread runtime context/result cells that intentionally use scalar arrays as
  raw shared storage until the thread API grows vector/owned-buffer join
  variants.

## Feature Coverage That Must Remain

These files intentionally exercise unsized arrays while generated vectors retain
array-backed storage.

- `tests/integration/array_*.tl`, `tests/integration/make_array*.tl`,
  `tests/integration/mutable_reference_array.tl`,
  `tests/integration/struct_field_set.tl`,
  `tests/integration/two_phase_mutable_call_borrow.tl`, and matching
  `tests/safety/*array*.tl` fixtures cover dynamic-array typing, bounds,
  borrow, move, and lowering behavior.
- `tests/spmd/*.tl` and SPMD integration tests use dynamic arrays as the current
  contiguous source/destination surface. The public SPMD vector/slice migration
  is separate from ordinary collection migration.
- `tests/integration/thread_safe_array_i64.tl` and thread runtime fixtures cover
  the currently implemented `thread.spawn-array-i64` / `thread.join-array-i64`
  aggregate transfer surface.
- `stdlib/tests/vector_slice_escape.tl` and vector/slice inline tests keep
  explicit array conversion coverage for `from-array`, `to-array`, and slice
  views.

## Follow-Up Rule

New public APIs must not expose unsized `(Array T)` as a growable collection.
Use generated vectors for owned growable storage, borrowed vector/slice views for
read-only traversal, and explicit byte-buffer/bytes surfaces for binary data.
When an unsized array remains, keep it documented as an internal backing buffer,
a compatibility boundary, or targeted feature coverage.
