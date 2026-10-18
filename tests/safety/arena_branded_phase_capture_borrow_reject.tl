(import stdlib.arena)

(define (main) : i64
  (let
    [owner (arena.make-atomic)]
    [phase (arena.phase owner)]
    [borrowed (& phase)]
    [callback
      (lambda () : i64
        borrowed.mark.handle)]
    (arena.rewind-safe! phase)
    (callback)))