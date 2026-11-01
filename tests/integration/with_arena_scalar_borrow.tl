;; The #9297 program. `r` borrows `y`, which outlives the `with-arena` form, so
;; the reference must not point into the arena the form rewinds: the next
;; allocation reuses that memory. Main before the fix returned 7.
(define (main) : i64
  (let
    [y : i64 42]
    [r : (& y i64) (with-arena tmp (& y))]
    [junk : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    (set! (array-ref junk 0) 7)
    (deref r)))