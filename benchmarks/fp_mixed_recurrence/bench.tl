;# Mixed integer and f64 leaf loop with a runtime trip count. The loop index
;# weights each term of the floating-point recurrence.
(import stdlib.io)
(import stdlib.math)

(define (mixed-f64-recurrence [n : i64] [x0 : f64] [a : f64] [b : f64]) : f64
  (let
    [x : f64 x0]
    [acc : f64 0.0]
    [i : i64 0]
    (while (< i n)
      (set! x (+ (* a x) b))
      (set! acc (+ acc (* (cast i : f64) x)))
      (set! i (+ i 1)))
    (+ acc x)))

;; Dispatch once through a stored function value to exercise the mixed GP/FP
;; entry ABI even when the recurrence is the only kernel in the benchmark.
(define run-recurrence : (-> i64 f64 f64 f64 f64)
  mixed-f64-recurrence)

(define (main) : i64
  (let
    [n : i64 (+ 20000000 (io.arg-count))]
    [sum : f64 (run-recurrence n 0.25 1.000001 0.5)]
    (io.println "{}" (math.f64-to-bits sum))
    0))