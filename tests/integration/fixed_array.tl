(import stdlib.array)

(define (main) : i64
  (let
    [a : (Array i64 3) (array 2 2 3)]
    (begin
      (array.array-set! a 1 40)
      (+ (array.array-ref a 0) (array.array-ref a 1)))))