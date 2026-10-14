(import stdlib.arena)

(define (overwrite [word : (&mut word i64)]) : unit
  (set! (deref word) 12345))

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    (begin
      (overwrite (&mut owner.handle))
      owner.handle)))