(import stdlib.arena)

(define (main) : i64
  (let
    [scratch : i64 0]
    (in-arena scratch 1)))