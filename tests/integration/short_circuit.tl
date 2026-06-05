;; tests/integration/short_circuit.tl
;;
;; `and`/`or` short-circuit: the right operand is evaluated only when the left
;; operand does not already decide the result (#1132). Each guarded right
;; operand divides by `n`, so a non-short-circuiting compiler would trap on the
;; n=0 calls; correct short-circuiting skips them and the program returns 42.
;;
;; `(- (arg-count) 1)` is a runtime-opaque zero (arg-count is 1 with no extra
;; arguments), which keeps the optimizer from constant-folding the guarded
;; division at compile time.
(import "stdlib/io.tl")

(define (sc-and [n : i64]) : bool
  (and (!= n 0) (= (/ 100 n) 100)))

(define (sc-or [n : i64]) : bool
  (or (= n 0) (= (/ 100 n) 100)))

(define (main) : i64
  (let
    [zero : i64 (- (arg-count) 1)]
    (if (sc-and zero)
      1
      (if (sc-or zero)
        42
        1))))