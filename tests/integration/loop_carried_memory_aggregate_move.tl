;; Refs #6214: a memory-class value produced in a loop uses one reusable
;; per-expression frame slot. Moving its handle into a loop-carried binding
;; must materialize stable storage before the next iteration overwrites that
;; producer slot.
(defstruct BigRec
  (f0 i64)
  (f1 i64)
  (f2 i64)
  (f3 i64)
  (f4 i64)
  (f5 i64)
  (f6 i64)
  (f7 i64)
  (f8 i64)
  (f9 i64)
  (f10 i64)
  (f11 i64))

(define (make-rec [x : i64]) : BigRec
  (BigRec x x x x x x x x x x x x))

(define (main) : i64
  (let
    [held : BigRec (make-rec -1)]
    [i : i64 0]
    [bad : i64 0]
    (begin
      (while (< i 10)
        (let
          [cur : BigRec (make-rec i)]
          (begin
            (when (> i 0) (unless (= held.f0 (- i 1)) (set! bad 1)))
            (set! held cur)
            (unless (= held.f0 i) (set! bad 2))
            (set! i (+ i 1)))))
      (if (= bad 0)
        42
        bad))))