;: The lane binding is read-only.
(define (main) : i64
  (begin
    (foreach ([i : i64 0 4]) (foreach-active [lane : i64] (set! lane 1)))
    0))