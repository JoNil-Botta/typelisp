# Memory and ownership

This page describes TypeLisp ownership, borrowing, boxes, and arenas. The
formal rules are in [SPEC.md](../SPEC.md).

TypeLisp implements structural copy/move semantics and lexical
immutable/mutable borrow checking with conservative non-lexical lifetime
shortening. There are no destructors, no general `free`, and no garbage
collector; heap allocation uses a backend-emitted bump allocator into the
active arena.

A by-value use copies a Copy value and leaves the source usable; it moves any
other value, and later uses of the moved source are rejected. Copy is decided
per type, recursively ([SPEC.md](../SPEC.md) section 4.7.2):

- **Copy leaves:** scalars (integers, floats, `bool`, `char`, `unit`), raw
  pointers, shared references `(& r T)` whatever `T` is, and named or
  non-capturing function values.
- **Copy aggregates:** a fixed array, tuple, struct or enum is Copy when every
  element, slot, field and variant payload is Copy. A capturing closure is
  Copy when every captured value is.
- **Move-only:** `String`, `ByteBuf`, bare `str`/`bytes` and `Slice` values
  (a shared reference to one is Copy), `(Box T)`, mutable references, and any
  aggregate or closure that contains one. A cleanup-owning struct or enum
  (declared with `(:cleanup ...)`) is always move-only, even when every part
  is Copy. A nominal aggregate whose classification reaches itself again is
  conservatively move-only.

So a record of scalar, fixed-array and shared-reference fields is Copy, while
one `String` field makes the whole record move:

```typelisp
(defstruct Span (start i64) (end i64)) ; every field is Copy: Span is Copy
(defstruct Label (name String) (span Span)) ; a String field: Label moves

(define (width [s : Span]) : i64
  (- s.end s.start))

(define (main) : i64
  (let
    [s : Span (Span 2 5)]
    (+ (width s) (width s)))) ; s is copied each time, never moved
```

Passing a `Label` by value twice the same way is rejected, because the first
call moves it; borrow it with `(& Label)` instead. See [SPEC.md](../SPEC.md)
sections 4.7.2 and 7 for the precise model.

`String` values are immutable at the source level; borrowing a `String`
place produces a borrowed `(& lifetime str)` view, and typed calls
auto-borrow borrowable places for immutable reference parameters.
`string.substring`/`string.slice` return fresh owned copies;
`string.substring-view`/`string.slice-view` return bounds-checked borrowed
slices without copying. Mutable binary storage is the owned `ByteBuf` plus
`(& lifetime bytes)` / `(&mut lifetime bytes)` borrowed views; conversions
between text, arrays, and byte buffers are explicit copy or borrow
boundaries.

Borrowed `(Slice T)` views are likewise allocation-free and never own or extend
the backing storage. A view carries the originating owner's provenance and
lifetime. Shared Slice views are copyable aliases; mutable Slice views are
exclusive and non-copying. `slice-view`/`slice-mut-view` subviews retain the
original owner borrow, so nested children keep that owner live until their last
use; conservative non-lexical last-use analysis then releases the borrow when
no child remains.

`(Box T)` is a safe, move-only, arena-owned indirection handle: `(box expr)`
allocates in the active arena, `(deref b)` projects the value, moving a
non-Copy projected value consumes the box, and `(set! (deref b) value)`
mutates boxed storage. A box allocated inside `(with-arena r ...)` cannot
escape that scope.

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
