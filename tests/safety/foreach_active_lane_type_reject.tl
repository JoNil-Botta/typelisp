;: The lane binding is always i64.
(define (main) : i64
  (begin
    (foreach ([i : i64 0 4]) (foreach-active [lane : i32] unit))
    0))