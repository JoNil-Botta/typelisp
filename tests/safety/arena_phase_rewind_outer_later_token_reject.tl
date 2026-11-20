;; #9480: rewinding a phase ends the later phase tokens too; rewinding `ph2`
;; after `ph1` would move the cursor into storage reused since.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [o : arena.Arena (arena.make)]
    [ph1 (arena.phase o)]
    [a (in-arena o (string.append "a" "-text"))]
    [n : i64 (string.string-length a)]
    [ph2 (arena.phase o)]
    (begin
      (arena.rewind-safe! ph1)
      (arena.rewind-safe! ph2)
      (+ n 36))))