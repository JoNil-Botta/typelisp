(import "stdlib/arena.tl")

(define (main) : i64
  (let
    [scratch : i64 0]
    (with-escape scratch 1)))