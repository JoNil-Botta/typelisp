(import stdlib.arena)
(import stdlib.string)

(define (render
  [keep : (& keep-handle (arena.Arena kept))]
  [other : (& other-handle (arena.Arena scratch))]
  [n : i64]) : (in kept String)
  (when (< n 0) (return (in-arena other (string.int->string n))))
  (in-arena keep (string.append "pos" "")))

(define (main) : i64
  (let
    [keep (arena.make)]
    [other (arena.make)]
    [text (render (& keep) (& other) -12345)]
    (arena.destroy-safe! other)
    (string.string-length text)))