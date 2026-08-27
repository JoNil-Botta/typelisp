# Private Dynamic Buffer Census

Public `Array` is fixed-size-only: source code uses `(Array T N)`. Unsized
`(Array T)` and the bare `make-array`, `array-push!`, and `array-data` forms are
rejected. This census records the remaining compiler-private
`(__tl_dyn-array T)` backing storage and the public abstractions that hide it.

## Public Collection Boundaries

- `stdlib/vector.tl` exposes generated vector modules whose reads take `&` and
  mutators take `&mut`; their backing storage is `__tl_dyn-array`.
- Generated queue, hashmap, set, and text-buffer families expose wrapper, Vec,
  or Slice types and keep capacity storage private.
- Argument parsing, weighted random selection, bulk String concatenation,
  compiler tooling, and the lexer/parser examples use generated vectors or
  borrowed Slice views at public boundaries.
- Binary APIs use `ByteBuf` and borrowed `bytes` views. Thread result APIs move
  owned wrappers rather than exposing their dynamic backing cells.

## Intentional Private Storage

- Binary and byte storage in `stdlib/byte_buf.tl`, `stdlib/byte_buf_core.tl`,
  `stdlib/ffi.tl`, `stdlib/io.tl`, `stdlib/fs.tl`, and
  `stdlib/process_runtime.tl`.
- Compiler scratch buffers, dense tables, captured-field lists, object/codegen
  byte streams, and serialized metadata in `src/*.tl`.
- Runtime and thread context/result cells whose public operations expose only
  owned wrappers, vectors, or borrowed views.
- Focused compiler, runtime, synchronization, byte-buffer, environment, and
  process fixtures that exercise private storage and lowering behavior.

These uses spell the type `__tl_dyn-array` and call private intrinsics such as
`__tl_make-array`, `__tl_array-push!`, and `__tl_array-data`. Public fixed-array
construction, length, indexing, and place writes are import-free core forms;
growable public collections use generated vectors.

## Coverage That Must Remain

- Array integration and safety fixtures cover private dynamic-buffer length,
  initialization, bounds, borrow, move, growth, and lowering behavior, plus
  rejection of the retired public spellings.
- SPMD runtime-sized inputs use borrowed native Slice surfaces; fixed-array
  fixtures retain public `(Array T N)` coverage.
- Generated-vector tests cover native-Slice lifetimes, traversal, mutation,
  growth/alias rejection, and owned copy boundaries without exposing private
  backing types.
- Thread and synchronization fixtures cover transfer of owned aggregates whose
  storage is backed by private buffers.

## Maintenance Rule

New public APIs must not expose `__tl_dyn-array` or recreate unsized `(Array T)`.
Use generated vectors for owned growable storage, borrowed Slice views for
traversal, fixed `(Array T N)` for statically sized storage, and explicit
`ByteBuf`/`bytes` surfaces for binary data. Add new private-buffer uses here only
when a compiler/runtime boundary genuinely requires raw growable backing.
