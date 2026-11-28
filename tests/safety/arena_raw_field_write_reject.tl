(import stdlib.arena)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    (begin
      (unsafe
        (set! owner.handle 0))
      (arena.raw-handle owner))))