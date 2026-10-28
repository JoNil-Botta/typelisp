;; Dead zero-sized array addresses must not survive stack-slot reuse.
(import stdlib.test)

(defstruct UnitRow
  (tag i64)
  (cells (Array unit 2))
  (tail i64))

(define (main) : i64
  (let
    [a : (__tl_dyn-array UnitRow)
      (__tl_make-array (UnitRow 10 (array unit unit) 20))]
    (test.assert-i64-eq (array-ref a 0).tail 20 "before growth")
    (__tl_array-push! a (UnitRow 30 (array unit unit) 40))
    (test.assert-i64-eq (array-ref a 0).tail 20 "old tail after growth")
    (test.assert-i64-eq (array-ref a 1).tail 40 "appended tail"))
  42)