(import stdlib.array)

(define (main) : i64
  (let
    [items : (Array i64) (array.make-array i64 1)]
    [borrowed : (&mut items (Array i64)) (&mut items)]
    (begin
      (array-set! borrowed 0 41)
      (array-length items))))