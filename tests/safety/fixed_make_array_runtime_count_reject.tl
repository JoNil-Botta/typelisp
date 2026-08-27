(define (make-items [count : i64]) : (Array i64 3)
  (make-array i64 count))

(define (main) : i64
  (array-ref (make-items 3) 0))