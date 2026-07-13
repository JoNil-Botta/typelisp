(define (bad [value : (& value i64) (:consume)]) : i64
  (ref-get value))

(define (main) : i64
  0)