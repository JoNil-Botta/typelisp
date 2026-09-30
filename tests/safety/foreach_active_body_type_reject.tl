;: Like foreach, foreach-active is unit and so is its body.
(define (main) : i64
  (begin
    (foreach ([i : i64 0 4]) (foreach-active [lane : i64] (+ i 1)))
    0))