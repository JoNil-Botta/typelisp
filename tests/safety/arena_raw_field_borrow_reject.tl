(import stdlib.arena)

(define (overwrite [word : (&mut word i64)]) : unit
  (set! (deref word) 0))

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    (begin
      (overwrite (&mut owner.handle))
      (arena.raw-handle owner))))