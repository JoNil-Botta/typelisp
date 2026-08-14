;: Replacing a whole root with an unresolved partial move cannot snapshot it.
(defstruct Owners
  (left (Box i64))
  (right (Box i64)))

(define (main) : i64
  (let
    [owners : Owners (Owners (box 1) (box 2))]
    [_left : (Box i64) owners.left]
    [_old : Owners (replace! owners (Owners (box 3) (box 4)))]
    42))