;; Keep the explicit-initialization variant as a passing control.
(import stdlib.test)

(defstruct Row
  (tag i64)
  (cells (Array unit 2))
  (tail i64))

(define (main) : i64
  (let
    [a : (__tl_dyn-array Row) (__tl_make-array Row 1)]
    (set! (array-ref a 0) (Row 10 (array unit unit) 20))
    (test.assert-i64-eq (array-ref a 0).tail 20 "before growth")
    (__tl_array-push! a (Row 30 (array unit unit) 40))
    (test.assert-i64-eq (array-ref a 0).tail 20 "after growth")
    42))