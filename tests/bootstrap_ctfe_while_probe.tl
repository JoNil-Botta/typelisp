;; Bootstrap capability probe for CTFE-local mutation, iteration, and the
;; generic expression-list conditional fold.
;;
;; Bootstrap scripts load the seed-only core macro compatibility path first, so
;; this source isolates whether the seed itself can evaluate the current
;; iterative macro-building surface in a transformer.
(import stdlib.comptime)

(defmacro (bootstrap-ctfe-while-probe [args : bool ...]) : bool
  (let
    [index : i64 0]
    (begin
      (while (< index 1)
        (set! index (+ index 1)))
      (if (= index 1)
        (comptime.expr-list-fold-if
          args
          (comptime.expr-bool true)
          (comptime.expr-bool false)
          true)
        (comptime.expr-bool false)))))

(defmacro (bootstrap-ctfe-clause-fold-probe [arms : ExprClause ...]) : bool
  (comptime.expr-clause-list-fold-if
    arms
    (comptime.expr-bool false)
    (comptime.expr-bool false)))

(define (main) : i64
  (if (bootstrap-ctfe-while-probe true true)
    (if (bootstrap-ctfe-clause-fold-probe [else true])
      0
      1)
    1))