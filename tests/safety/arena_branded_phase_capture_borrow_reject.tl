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
    [view (& callback)]
    (arena.rewind-safe! phase)
    (let
      [callee (deref view)]
      (callee))))