(import stdlib.arena)
(import stdlib.string)

(define (render [owner : (& handle (arena.Arena source))] [n : i64]) : String
  (let
    [make-text : (-> String)
      (lambda () : String
        (return (in-arena owner (string.int->string n))))]
    (make-text)))

(define (main) : i64
  (let
    [owner (arena.make)]
    [text (render (& owner) -12345)]
    (arena.destroy-safe! owner)
    (string.string-length text)))