;; #7963: inline 16-byte `(__tl_dyn-array T)` descriptors live in the binder's
;; frame slot, so borrowing an inner `(in r (__tl_dyn-array i64))` past its let
;; scope must be rejected.
(import stdlib.arena)

(define (main) : i64
  (let
    [o (arena.make)]
    [r : (& o (__tl_dyn-array i64))
      (with-arena
        inner
        (let
          [xs (in-arena o (__tl_make-array i64 2))]
          (& xs)))]
    (array-length r)))