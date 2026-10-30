;; Refs #9502 Refs #9493. Ending a different off-stack arena is safe, including source-name shadowing.
(import stdlib.arena)

(define (exercise [owner : (arena.Arena r) (:invalidate r)]) : i64
  (begin
    (in-arena
      owner
      (with-arena
        s
        (let
          [other (arena.make)]
          (begin
            (arena.destroy-safe! other)
            42))))
    (arena.destroy-safe! owner)
    42))

(define (main) : i64
  (let
    [owner (arena.make)]
    (exercise owner)))