;; #9687: module-hook given a type-cleanup-function name for an entry type.
(import stdlib.comptime)
(import stdlib.string)

(define hits : i64
  0)

(define (close-tok [_v : i64]) : unit
  (set! hits (+ hits 1)))

(defstruct Own
  (:cleanup clean)
  (v i64 (:cleanup close-tok)))

(defmacro (m [X : type]) : Expr
  (comptime.expr-call
    (comptime.module-hook (type-nominal-module X) (type-cleanup-function X))
    (comptime.expr-list-cons (comptime.expr-var "o") (comptime.expr-list-empty))))

(define (main) : i64
  (let
    [o (Own 1)]
    (m Own)
    (+ 41 hits)))