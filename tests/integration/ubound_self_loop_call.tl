;; Tail conversion keeps this clean callee out of an ordinary caller's inline
;; walk, leaving a single-block loop whose array check precedes the call.
(import stdlib.io)
(import stdlib.string)

(defstruct Scan
  (slots (__tl_dyn-array i64))
  (len i64))

(define (clean [value : i64] [depth : i64] [divisor : i64]) : i64
  (if (> depth 0)
    (clean (+ value 1) (- depth 1) divisor)
    (/ value divisor)))

(define (scan [s : (& Scan)] [depth : i64] [step : i64] [divisor : i64]) : i64
  (let
    [n : i64 s.len]
    [i : i64 0]
    [acc : i64 0]
    (while (< i n)
      (begin
        (set! acc (+ acc (clean (array-ref s.slots i) depth divisor)))
        (set! i (+ i step))))
    acc))

(define (main) : i64
  (if (!= (io.arg-count) 6)
    1
    (let
      [capacity : i64 (string.>int (io.arg 1))]
      [bound : i64 (string.>int (io.arg 2))]
      [depth : i64 (string.>int (io.arg 3))]
      [step : i64 (string.>int (io.arg 4))]
      [divisor : i64 (string.>int (io.arg 5))]
      [s : Scan (Scan (__tl_make-array i64 capacity) bound)]
      (io.print-format "{}\n" (scan (& s) depth step divisor))
      42)))