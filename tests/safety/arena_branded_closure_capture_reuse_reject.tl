(import stdlib.arena)

(define (main) : i64
  (let
    [owner (arena.make)]
    [_read : (-> i64)
      (lambda () : i64
        (arena.raw-handle owner))]
    (arena.raw-handle owner)))