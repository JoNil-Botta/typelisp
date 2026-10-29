(import stdlib.arena)
(import stdlib.string)

(defenum Pick
  (Owned)
  (Plain))

(define (render
  [owner : (& handle (arena.Arena source))]
  [pick : Pick]
  [n : i64]) : String
  (match pick
    [(Pick.Owned) (return (in-arena owner (string.int->string n)))]
    [(Pick.Plain) (string.append "plain" "")]))

(define (main) : i64
  (let
    [owner (arena.make)]
    [text (render (& owner) Pick.Owned -12345)]
    (arena.destroy-safe! owner)
    (string.string-length text)))