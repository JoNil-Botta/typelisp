(define k : i64
  (comptime (cond [else 1] [false 2])))

(define (main) : i64
  k)