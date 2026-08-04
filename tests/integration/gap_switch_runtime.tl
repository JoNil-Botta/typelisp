(import stdlib.array)

;; Twelve variants; the match names nine of them and lets 3, 6 and 10 fall to a
;; catch-all. The formed table must route those three tags to the default arm.
(defenum GapTag
  (T0)
  (T1)
  (T2)
  (T3)
  (T4)
  (T5)
  (T6)
  (T7)
  (T8)
  (T9)
  (T10)
  (T11))

(define (gap-score [value : GapTag]) : i64
  (match value
    [(GapTag.T0) 1]
    [(GapTag.T1) 2]
    [(GapTag.T2) 3]
    [(GapTag.T4) 5]
    [(GapTag.T5) 6]
    [(GapTag.T7) 8]
    [(GapTag.T8) 9]
    [(GapTag.T9) 10]
    [(GapTag.T11) 12]
    [_ 100]))

(define (main) : i64
  (let
    [values : (__tl_dyn-array GapTag) (array.make-array GapTag 12)]
    [i : i64 0]
    [sum : i64 0]
    (begin
      (array-set! values 0 (GapTag.T0))
      (array-set! values 1 (GapTag.T1))
      (array-set! values 2 (GapTag.T2))
      (array-set! values 3 (GapTag.T3))
      (array-set! values 4 (GapTag.T4))
      (array-set! values 5 (GapTag.T5))
      (array-set! values 6 (GapTag.T6))
      (array-set! values 7 (GapTag.T7))
      (array-set! values 8 (GapTag.T8))
      (array-set! values 9 (GapTag.T9))
      (array-set! values 10 (GapTag.T10))
      (array-set! values 11 (GapTag.T11))
      (while (< i 12)
        (begin
          (set! sum (+ sum (gap-score (array.ref values i))))
          (set! i (+ i 1))))
      ;; 1+2+3+100+5+6+100+8+9+10+100+12 = 356
      (if (= sum 356)
        42
        1))))