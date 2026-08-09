(import stdlib.array)

(define (main) : i64
  (let
    [a : (__tl_dyn-array i64) (array.make-array i64 8)]
    [out-x : (__tl_dyn-array i64) (array.make-array i64 8)]
    [out-y : (__tl_dyn-array i64) (array.make-array i64 3)]
    (begin
      (foreach
        ([i : i64 0 8])
        (begin
          (array-set! out-x i (+ (array-ref a i) 1))
          (array-set! out-y i (+ (array-ref a i) 2))))
      0)))