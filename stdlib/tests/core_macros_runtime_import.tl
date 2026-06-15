(import stdlib.io)

(define (sc-and [n : i64]) : bool
  (and (!= n 0) (= (/ 100 n) 100)))

(define (sc-or [n : i64]) : bool
  (or (= n 0) (= (/ 100 n) 100)))

(define (guard-score [n : i64]) : i64
  (let
    [value : i64 0]
    (begin
      (when (= n 0) (set! value 11))
      (unless (!= n 0) (set! value (+ value 31)))
      value)))

(define (main) : i64
  (let
    [zero : i64 (- (io.arg-count) 1)]
    (if (sc-and zero)
      1
      (if (sc-or zero)
        (if (= (guard-score zero) 42)
          42
          1)
        1))))