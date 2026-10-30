;; Refs #9502 Refs #9493. Ending a different off-stack arena is safe, including source-name shadowing.
(import stdlib.arena)

(define (main) : i64
  (let
    [o : arena.Arena (arena.make)]
    (begin
      (in-arena
        o
        (with-arena
          s
          (let
            [o : arena.Arena (arena.make)]
            (begin
              (arena.destroy-safe! o)
              42))))
      (arena.destroy-safe! o)
      42)))