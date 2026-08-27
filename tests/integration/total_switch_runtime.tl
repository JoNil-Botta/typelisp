
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
    [(TotalSwitchValue.Zero) 1]
    [(TotalSwitchValue.One) 2]
    [(TotalSwitchValue.Two) 4]
    [(TotalSwitchValue.Three) 8]
    [(TotalSwitchValue.Four) 10]
    [(TotalSwitchValue.Five) 17]))

(define (main) : i64
  (let
    [values : (__tl_dyn-array TotalSwitchValue)
      (__tl_make-array TotalSwitchValue 6)]
    [i : i64 0]
    [sum : i64 0]
    (begin
      (set! (array-ref values 0) (TotalSwitchValue.Zero))
      (set! (array-ref values 1) (TotalSwitchValue.One))
      (set! (array-ref values 2) (TotalSwitchValue.Two))
      (set! (array-ref values 3) (TotalSwitchValue.Three))
      (set! (array-ref values 4) (TotalSwitchValue.Four))
      (set! (array-ref values 5) (TotalSwitchValue.Five))
      (while (< i 6)
        (begin
          (set! sum (+ sum (total-switch-score (array.ref values i))))
          (set! i (+ i 1))))
      (if (= sum 42)
        42
        1))))