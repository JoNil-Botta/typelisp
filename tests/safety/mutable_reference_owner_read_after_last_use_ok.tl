(import stdlib.array)

(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (array.make-array i64 1)]
    [borrowed : (&mut items (__tl_dyn-array i64)) (&mut items)]
    (begin
      (array-set! borrowed 0 41)
      (array-length items))))