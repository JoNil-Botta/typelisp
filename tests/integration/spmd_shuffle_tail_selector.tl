; A single partial SIMD gang with an exactly-sized varying-selector array.
; Inactive destination lanes must not read either input past element 2.
(import stdlib.array)

(define (main) : i64
  (let
    [n : i64 3]
    [xs : (Array i64) (array.make-array i64 n)]
    [selectors : (Array i64) (array.make-array i64 n)]
    [out : (Array i64) (array.make-array i64 n)]
    (begin
      (array-set! xs 0 11)
      (array-set! xs 1 22)
      (array-set! xs 2 33)
      (array-set! selectors 0 0)
      (array-set! selectors 1 1)
      (array-set! selectors 2 2)
      (foreach
        ([i : i64 0 n])
        (array-set!
          out
          i
          (spmd-shuffle (array-ref xs i) (array-ref selectors i))))
      (if (and
        (= (array-ref out 0) 11)
        (= (array-ref out 1) 22)
        (= (array-ref out 2) 33))
        42
        1))))