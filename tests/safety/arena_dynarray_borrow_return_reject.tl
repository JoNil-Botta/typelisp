;; #7963: inline 16-byte `(__tl_dyn-array T)` descriptors live in the binder's
;; frame slot, so returning a borrow of a local `(in r (__tl_dyn-array i64))`
;; must be rejected instead of escaping a dangling stack pointer.
(import stdlib.arena)

(define (mk-arr [a : (arena.Arena r)]) : (& r (__tl_dyn-array i64))
  (in-arena
    a
    (let
      [xs (__tl_make-array i64 2)]
      (& xs))))

(define (main) : i64
  (let
    [o (arena.make)]
    [xs (mk-arr o)]
    (array-length xs)))