(define (bad [value : (&mut value i64) (:consume)]) : i64
  (ref-get value))

(define (main) : i64
  0)