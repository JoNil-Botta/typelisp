;: `in-arena` does not weaken lexical `with-arena` escape checking.
(import stdlib.arena)
(import stdlib.string)

(define (main) : String
  (let
    [scratch : arena.Arena (arena.make)]
    (in-arena scratch (with-arena inner (string.int->string 1)))))
