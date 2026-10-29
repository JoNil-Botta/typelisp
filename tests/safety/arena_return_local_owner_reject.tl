(import stdlib.arena)
(import stdlib.string)

(define (leak [n : i64]) : String
  (let
    [owner (arena.make)]
    (in-arena owner (return (string.int->string n)))))

(define (main) : i64
  (string.string-length (leak 42)))