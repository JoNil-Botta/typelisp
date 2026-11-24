(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [dead : arena.Arena (with-scratch (arena.current))]
    (in-arena dead (string.string-length (string.int->string 42)))))