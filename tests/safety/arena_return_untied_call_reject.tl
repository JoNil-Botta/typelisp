(import stdlib.arena)
(import stdlib.string)

(define (make [owner : (& handle (arena.Arena source))] [n : i64]) : (in
    source
    String)
  (in-arena owner (string.int->string n)))

(define (render [owner : (& handle (arena.Arena source))] [n : i64]) : String
  (when (< n 0) (return (make owner n)))
  (string.append "pos" ""))

(define (main) : i64
  (let
    [owner (arena.make)]
    [text (render (& owner) -12345)]
    (arena.destroy-safe! owner)
    (string.string-length text)))