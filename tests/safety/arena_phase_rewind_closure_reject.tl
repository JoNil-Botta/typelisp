;; #9479: a branded owner's phase covers a capturing closure's environment
;; allocated by `in-arena`, so its rewind ends the closure.
(import stdlib.arena)

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    [f
      (in-arena
        owner
        (let
          [x : i64 40]
          (lambda () : i64
            (+ x 2))))]
    (begin
      (arena.rewind-safe! p)
      (f))))