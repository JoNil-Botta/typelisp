(define (main) : i64
  (let
    [outer : (Box (Box i64)) (box (box 1))]
    [inner : (Box i64) (deref outer)]
    (begin
      (deref inner)
      (deref (deref outer)))))