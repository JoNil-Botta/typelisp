;: spmd-reduce values are gangs too, but not foreach bodies.
(define (main) : i64
  (spmd-reduce
    sum
    ([i : i64 0 4])
    0
    (begin
      (foreach-active [lane : i64] unit)
      i)))