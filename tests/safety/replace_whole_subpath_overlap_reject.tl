;: Reserving a whole aggregate rejects moving one of its fields into itself.
(defstruct Owners
  (left (Box i64))
  (right (Box i64)))

(define (main) : i64
  (let
    [owners : Owners (Owners (box 1) (box 2))]
    [_old : Owners (replace! owners (Owners owners.left (box 3)))]
    42))