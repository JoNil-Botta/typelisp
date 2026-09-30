;: The binding is [lane : i64].
(define (main) : i64
  (begin
    (foreach ([i : i64 0 4]) (foreach-active [lane i64] unit))
    0))