# Memory and ownership

This page describes TypeLisp ownership, borrowing, boxes, and arenas. The
formal rules are in [SPEC.md](../SPEC.md).

TypeLisp implements move-only aggregate semantics and lexical
immutable/mutable borrow checking with conservative non-lexical lifetime
shortening. There are no destructors, no general `free`, and no garbage
collector; heap allocation uses a backend-emitted bump allocator into the
active arena. Scalars, raw pointers, and non-capturing function values are
copyable; `String`, arrays, tuples, structs, enums, and capturing closures
move in by-value positions. See [SPEC.md](../SPEC.md) sections 4.7.2 and 7 for
the precise model.

`String` values are immutable at the source level; borrowing a `String`
place produces a borrowed `(& lifetime str)` view, and typed calls
auto-borrow borrowable places for immutable reference parameters.
`substring`/`string-slice` return fresh owned copies;
`substring-view`/`string-slice-view` return bounds-checked borrowed slices
without copying. Mutable binary storage is the owned `ByteBuf` plus
`(& lifetime bytes)` / `(&mut lifetime bytes)` borrowed views; conversions
between text, arrays, and byte buffers are explicit copy or borrow
boundaries.

`(Box T)` is a safe, move-only, arena-owned indirection handle: `(box expr)`
allocates in the active arena, `(box-get b)` projects the value, `(box-take
b)` consumes the box, and `(set! (box-get b) value)` mutates boxed storage.
A box allocated inside `(with-arena r ...)` cannot escape that scope.

### Arenas

The first safe reclamation surface is `(with-arena r body ...)` — a
lexically scoped arena with static escape checking: the typechecker rejects
any arena-tagged value that would leave the scope, so the compiler can
safely reset the region afterwards. On top of that, `stdlib.arena` provides
typed first-class arenas. The standard patterns:

- `(with-arena scratch ...)` for temporary work returning only scalars or
  outer-owned values; nest scopes for stack-shaped lifetimes (level/frame).
- `(with-escape scratch ...)` with an `arena.make` arena, or
  `(with-scratch ...)` for one-shot work, when one supported result must be
  cloned out.
- `(in-arena arena body ...)` when results should remain owned by a
  first-class arena; `(arena.make-atomic)` for a shared atomic allocation
  target across threads.
- `arena.phase` plus `arena.rewind-safe!` / `arena.destroy-safe!` for
  checker-proven arena invalidation: the checker rejects the reset while any
  values, borrows, captures, or owner handles from that arena remain live.
- Raw `arena.set!` / `arena.rewind` / `arena.destroy` require
  `(unsafe ...)`.

The runnable cookbook in
[`../examples/arena_lifetimes.tl`](../examples/arena_lifetimes.tl) covers lexical
frame scopes, double-buffered frame arenas, and event-driven unload. Scoped
cleanup of non-memory resources is separate:
`(with ([name init cleanup]) body ...)` runs cleanup functions in reverse
binding order on scope exit (files, locks, process handles); it does not
imply destructors or arena resets.
