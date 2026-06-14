(define (thread-spawn-i64 [value : i64]) : i64
  (+ value 1))

(define (main) : i64
  (thread-spawn-i64 41))