(define (spawn [value : i64]) : i64
  (+ value 1))

(define (main) : i64
  (spawn 41))