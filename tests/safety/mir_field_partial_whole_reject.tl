;: A value whose field moved out cannot be used whole, even by reference.
(defstruct Holder
  (items (__tl_dyn-array i64))
  (count i64))

(define (take [_items : (__tl_dyn-array i64)]) : i64
  1)

(define (count-of [h : (& h Holder)]) : i64
  h.count)

(define (run [h : Holder]) : i64
  (+ (take h.items) (count-of h)))

(define (main) : i64
  0)