(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner (arena.make-atomic)]
    [phase (arena.phase owner)]
    [text (in-arena phase (string.append "captured" "-phase"))]
    [callback
      (lambda () : i64
        (string.string-length text))]
    (arena.rewind-safe! phase)
    (callback)))