;; refs #1867: array-push! of an inline struct element into a dynamic array
;; byte-copies the whole element into the correctly-strided slot instead of
;; truncating to 8 bytes / striding by 8. main returns 42 only when both pushed
;; structs read back through array-ref with their fields intact.
(defstruct P
  (x i64)
  (y i64))

(define (main) : i64
  (let
    [a : (Array P) (make-array P 0)]
    (begin
      (array-push! a (P 30 5))
      (array-push! a (P 100 7))
      (+
        (struct-get (array-ref a 0) x)
        (+ (struct-get (array-ref a 0) y) (struct-get (array-ref a 1) y))))))