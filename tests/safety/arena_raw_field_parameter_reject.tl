(import stdlib.arena)

(define (overwrite [owner : (&mut owner arena.Arena)]) : unit
  (set! owner.handle 12345))

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    (begin
      (overwrite (&mut owner))
      owner.handle)))