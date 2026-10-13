;: A field moved on one branch is maybe-moved after the join.
(defstruct Holder
  (items (__tl_dyn-array i64))
  (count i64))

(define (take [_items : (__tl_dyn-array i64)]) : i64
  1)

(define (run [h : Holder] [flag : bool]) : i64
  (+
    (if flag
      (take h.items)
      0)
    (take h.items)))

(define (main) : i64
  0)