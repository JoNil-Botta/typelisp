;; macro_forward_order.tl - local macros are visible across their whole module.
;; `main` uses both macros before their definitions. `outer` also expands to a
;; later macro.
(define (main) : i64
  (+ (outer true) (sum-later 10 12)))

(defmacro (outer [flag : bool]) : i64
  `(choose ,flag 20 0))

(defmacro (sum-later [lhs : i64] [rhs : i64]) : i64
  `(+ ,lhs ,rhs))

(defmacro (choose [condition : bool] [then-expr : Expr] [else-expr : Expr]) : Expr
  `(if ,condition
    ,then-expr
    ,else-expr))