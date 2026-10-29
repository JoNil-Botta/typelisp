(import stdlib.arena)
(import stdlib.string)

(define (render [owner : (& handle (arena.Arena source))] [n : i64]) : String
  (in-arena owner (when (< n 0) (return (string.int->string n))))
  (string.append "pos" ""))

(define (main) : i64
  (let
    [owner (arena.make)]
    [text (render (& owner) -12345)]
    (arena.destroy-safe! owner)
    (string.string-length text)))