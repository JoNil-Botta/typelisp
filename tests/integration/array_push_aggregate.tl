;; refs #1867/#3581: compatibility dynamic-array `array-push!` of an inline
;; struct element byte-copies the whole element into the correctly-strided slot
;; instead of truncating to 8 bytes / striding by 8. main returns 42 only when
;; both pushed structs read back through array-ref with their fields intact.
(import stdlib.array)

(defstruct P
  (x i64)
  (y i64))

(define (main) : i64
  (let
    [a : (Array P) (array.make-array P 0)]
    (begin
      (array.array-push! a (P 30 5))
      (array.array-push! a (P 100 7))
      (+
        (struct-get (array.array-ref a 0) x)
        (+
          (struct-get (array.array-ref a 0) y)
          (struct-get (array.array-ref a 1) y))))))