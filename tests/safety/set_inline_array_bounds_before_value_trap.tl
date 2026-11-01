;; Indexing an element's inline array reads that element, so its bounds check
;; runs before the value.
(defstruct Row
  (tag i64)
  (cells (Array i64 2)))

(define (main) : i64
  (let
    [a : (__tl_dyn-array Row) (__tl_make-array Row 0)]
    (set! (array-ref (array-ref a 1).cells 0) (shl (cast 1 : i64) -1))
    0))