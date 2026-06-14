;: `in-arena` does not weaken lexical `with-arena` escape checking.
(import "stdlib/arena.tl")

(import "stdlib/string.tl")

(define (main) : String
  (let
    [scratch : i64 (arena-make)]
    (in-arena scratch (with-arena inner (int->string 1)))))