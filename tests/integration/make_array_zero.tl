(import stdlib.array)

(define (main) : i64
  (let
    [a : (__tl_dyn-array i64) (array.make-array i64 0)]
    (length a)))