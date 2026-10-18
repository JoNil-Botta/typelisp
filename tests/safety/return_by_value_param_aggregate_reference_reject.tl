;: A tuple or fixed array returning a borrow of a by-value parameter escapes
;: the call's storage as well (main accepted both).
(define (make-ref-tuple [n : i64]) : (Tuple (& n i64) i64)
  (tuple (& n) 7))

(define (make-ref-array [n : i64]) : (Array (& n i64) 1)
  (array (& n)))

(define (main) : i64
  (deref (tuple-ref (make-ref-tuple 42) 0)))