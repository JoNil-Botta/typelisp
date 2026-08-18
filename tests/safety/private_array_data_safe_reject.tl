;; The private spelling is the same unsafe raw-storage capability as the
;; transitional public compatibility spelling.
(define (data [items : (__tl_dyn-array i64)]) : (MutPtr i64)
  (__tl_array-data items))

(define (main) : i64
  0)