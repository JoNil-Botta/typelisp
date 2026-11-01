;; The inner fixed-array check is final even when its root is dynamic.
;; Its invalid index must not preempt the value's trap (SPEC 5.10).
(defstruct Row
  (tag i64)
  (cells (Array i64 3)))

(define (main) : i64
  (let
    [a : (__tl_dyn-array Row) (__tl_make-array Row 1)]
    [j : i64 3]
    (set! (array-ref (array-ref a 0).cells j) (shl (cast 1 : i64) -1))
    0))