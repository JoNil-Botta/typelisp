(import stdlib.array)

;; Two active lanes are invalid. SIMD lowering must validate in logical lane
;; order and abort before issuing the gather; lane 1 is therefore the selected
;; failure even when both invalid indexes share one hardware gang.
(define (main) : i64
  (let
    [xs : (Array i64) (array.make-array i64 8)]
    [ix : (Array i64) (array.make-array i64 8)]
    [out : (Array i64) (array.make-array i64 8)]
    (begin
      (array-set! ix 0 0)
      (array-set! ix 1 9223372036854775807)
      (array-set! ix 2 1)
      (array-set! ix 3 (- 0 1))
      (array-set! ix 4 2)
      (array-set! ix 5 3)
      (array-set! ix 6 4)
      (array-set! ix 7 5)
      (foreach
        ([i : i64 0 8])
        (array-set! out i (array-ref xs (array-ref ix i))))
      1)))