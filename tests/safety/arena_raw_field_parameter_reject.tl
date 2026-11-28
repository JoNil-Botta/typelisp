(import stdlib.arena)

(define (overwrite [owner : (&mut owner arena.Arena)]) : unit
  (set! owner.handle 0))

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    (begin
      (overwrite (&mut owner))
      (arena.raw-handle owner))))