;; Two scalar fields remain the control for the memory-class zero-array row.
(import stdlib.test)

(defstruct Row
  (tag i64)
  (tail i64))

(define (main) : i64
  (let
    [a : (__tl_dyn-array Row) (__tl_make-array (Row 10 20))]
    (test.assert-i64-eq (array-ref a 0).tail 20 "before growth")
    (__tl_array-push! a (Row 30 40))
    (test.assert-i64-eq (array-ref a 0).tail 20 "old tail without zero field")
    (test.assert-i64-eq
      (array-ref a 1).tail
      40
      "appended tail without zero field"))
  42)