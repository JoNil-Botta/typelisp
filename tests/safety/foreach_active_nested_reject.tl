;: A foreach-active body is already serialized; it cannot nest another.
(define (main) : i64
  (begin
    (foreach
      ([i : i64 0 4])
      (foreach-active [a : i64] (foreach-active [b : i64] unit)))
    0))