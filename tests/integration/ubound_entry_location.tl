;; The cursor has two data-dependent advances, leaving a multi-block loop.
;; The array check precedes division, including on the first and later trips.
(import stdlib.io)
(import stdlib.string)

(defstruct Scan
  (slots (__tl_dyn-array i64))
  (len i64))

(define (scan [s : (& Scan)] [step : i64] [divisor : i64]) : i64
  (let
    [n : i64 s.len]
    [i : i64 0]
    [acc : i64 0]
    (while (< i n)
      (begin
        (set! acc (+ acc (+ 1 (/ (array-ref s.slots i) divisor))))
        (set!
          i
          (if (= i 1)
            (+ i step)
            (+ i (* 2 step))))))
    acc))

(define (main) : i64
  (if (!= (io.arg-count) 5)
    1
    (let
      [capacity : i64 (string.>int (io.arg 1))]
      [bound : i64 (string.>int (io.arg 2))]
      [step : i64 (string.>int (io.arg 3))]
      [divisor : i64 (string.>int (io.arg 4))]
      [s : Scan (Scan (__tl_make-array i64 capacity) bound)]
      (io.print-format "{}\n" (scan (& s) step divisor))
      42)))