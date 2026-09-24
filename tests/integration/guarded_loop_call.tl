(import stdlib.io)

(define (probe [values : (& values (__tl_dyn-array i64))] [divisor : i64]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i (array-length values))
        (begin
          (set! total (+ total (array-ref values i)))
          (set! i (+ i 1))))
      (/ total divisor))))

;; The result is invariant, but the recurrence, counter and live exit value
;; vary. Non-unit strides and wraparound must survive guard duplication.
(define (repeat
  [values : (& values (__tl_dyn-array i64))]
  [end : i64]
  [start : i64]
  [step : i64]
  [divisor : i64]) : i64
  (let
    [i : i64 start]
    [total : i64 0]
    (begin
      (while (< i end)
        (begin
          (let
            [value : i64 (probe values divisor)]
            (set! total (+ (+ (* total 17) value) i)))
          (set! i (+ i step))))
      (+ total i))))

(define (main) : i64
  (let
    [values : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [i : i64 0]
    (begin
      (while (< i 8)
        (begin
          (set! (array-ref values i) (+ i 1))
          (set! i (+ i 1))))
      (io.println
        "{} {} {} {} {}"
        (repeat (& values) (- (io.arg-count) 1) 0 1 0)
        (repeat (& values) (- 0 2) 0 1 0)
        (repeat (& values) 1 0 1 1)
        (repeat (& values) 5 (- 0 3) 2 2)
        (repeat (& values) 31 0 1 1))
      0)))