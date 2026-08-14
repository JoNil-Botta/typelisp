;: Replacing the selected moved field cannot manufacture its old owner.
(defstruct Owners
  (left (Box i64))
  (right (Box i64)))

(define (main) : i64
  (let
    [owners : Owners (Owners (box 1) (box 2))]
    [_left : (Box i64) owners.left]
    [_old : (Box i64) (replace! owners.left (box 3))]
    42))