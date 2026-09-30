;: return cannot leave a foreach-active body.
(define (main) : i64
  (begin
    (foreach ([i : i64 0 4]) (foreach-active [lane : i64] (return 1)))
    0))