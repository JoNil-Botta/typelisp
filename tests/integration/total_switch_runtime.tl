;; A dynamic six-variant enum dispatch: every valid tag must reach its explicit
;; arm at both opt0 (comparison chain) and opt2 (total jump table).
(defenum TotalSwitchValue
  (Zero)
  (One)
  (Two)
  (Three)
  (Four)
  (Five))

(define (total-switch-score [value : TotalSwitchValue]) : i64
  (match value
    [(Zero) 1]
    [(One) 2]
    [(Two) 4]
    [(Three) 8]
    [(Four) 10]
    [(Five) 17]))

(define (main) : i64
  (let
    [values : (__tl_dyn-array TotalSwitchValue)
      (__tl_make-array TotalSwitchValue 6)]
    [i : i64 0]
    [sum : i64 0]
    (begin
      (set! (array-ref values 0) (Zero))
      (set! (array-ref values 1) (One))
      (set! (array-ref values 2) (Two))
      (set! (array-ref values 3) (Three))
      (set! (array-ref values 4) (Four))
      (set! (array-ref values 5) (Five))
      (while (< i 6)
        (begin
          (set! sum (+ sum (total-switch-score (array-ref values i))))
          (set! i (+ i 1))))
      (if (= sum 42)
        42
        1))))