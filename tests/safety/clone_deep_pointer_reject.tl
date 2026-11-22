(import stdlib.clone)

(define (duplicate [source : (Tuple (Ptr i64) i64)]) : (Tuple (Ptr i64) i64)
  (clone.deep source))