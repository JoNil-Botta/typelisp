(import stdlib.clone)

(define (duplicate [source : (-> i64 i64)]) : (-> i64 i64)
  (clone.deep source))