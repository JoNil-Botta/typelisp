(import stdlib.comptime as ct)
(import macro_body_sequence_dep as dep)

;; Discarded non-unit values distinguish the body sequence from a unit-only
;; body. Each last form must supply the macro's expansion.
(defmacro (two [items : Expr ...]) : i64
  (ct.expr-list-length items)
  (ct.expr-int 42))

(defmacro (three [value : Expr]) : i64
  (ct.expr-int 11)
  (ct.expr-int 22)
  value)

(defmacro (single [value : Expr]) : i64
  value)

(define (main) : i64
  (if (and
    (= (two 1 2) 42)
    (= (three 42) 42)
    (= (single 42) 42)
    (= (dep.two 1 2) 42)
    (= (dep.three 42) 42)
    (= (dep.single 42) 42))
    42
    1))