(define k : i64
  (comptime (cond [false 1])))

(define (main) : i64
  k)