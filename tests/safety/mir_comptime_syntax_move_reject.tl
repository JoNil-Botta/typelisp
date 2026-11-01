;; Comptime syntax values are ordinary move-only declarations (SPEC 3.7.1.2):
;; an `Expr` holds strings and boxed nodes, so using one twice is a use of a
;; moved value.
(import stdlib.comptime)

(define (twice [item : Expr]) : ExprList
  (let
    [first : Expr item]
    [second : Expr item]
    (comptime.expr-list-cons
      first
      (comptime.expr-list-cons second (comptime.expr-list-empty)))))

(define (main) : i64
  0)