;; Bootstrap capability probe for CTFE-local mutation and iteration.
;;
;; Bootstrap scripts load the seed-only core macro compatibility path first, so
;; this source isolates whether the seed itself can evaluate `while` in a macro
;; transformer.
(import stdlib.comptime)

(defmacro (bootstrap-ctfe-while-probe) : i64
  (let
    [index : i64 0]
    (begin
      (while (< index 1)
        (set! index (+ index 1)))
      (comptime.expr-int index))))

(define (main) : i64
  (if (= (bootstrap-ctfe-while-probe) 1)
    0
    1))
