;: A constructor moves its operand; the moved value cannot be used again.
(defstruct Holder
  (items (__tl_dyn-array i64))
  (count i64))

(define (run [items : (__tl_dyn-array i64)]) : i64
  (let
    [h : Holder (Holder items 1)]
    (+ h.count (array-length items))))

(define (main) : i64
  0)