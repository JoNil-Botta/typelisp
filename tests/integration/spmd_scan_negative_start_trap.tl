; A negative active scan start must retain the ordinary array bounds abort.
; AVX2 must enter the scalar path without overflowing its gang-width add.
(import stdlib.array)

(define (main) : i64
  (let
    [xs : (Array i64) (array.make-array i64 4)]
    [out : (Array i64) (array.make-array i64 4)]
    (begin
      (spmd-scan
        sum
        ([i : i64 (- 0 1) 3] [prefix : i64 0])
        (array-ref xs i)
        (array-set! out i prefix))
      42)))