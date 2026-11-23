(import stdlib.clone)

(define (duplicate [source : (& source i64)]) : (& source i64)
  (clone.deep source))