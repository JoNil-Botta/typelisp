(import stdlib.array)

;; Lane 0 overflows `i + offset` from i64::MAX to i64::MIN. Checked lowering
;; must preserve signed wrapping arithmetic, validate in logical lane order,
;; and abort before issuing the hardware gather. The later negative lane also
;; verifies that no gather runs after the first invalid active lane.
(define (main) : i64
  (let
    [xs : (Array i64) (array.make-array i64 8)]
    [offsets : (Array i64) (array.make-array i64 16)]
    [out : (Array i64) (array.make-array i64 9)]
    (begin
      (array-set! offsets 0 9223372036854775807)
      (array-set! offsets 1 0)
      (array-set! offsets 2 0)
      (array-set! offsets 3 (- 0 7))
      (foreach
        ([i : i64 1 9])
        (array-set!
          out
          i
          (array-ref xs (+ i (array-ref offsets (program-index))))))
      1)))