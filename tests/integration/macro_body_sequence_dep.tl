(import stdlib.comptime as ct)

(defmacro (two [items : Expr ...]) : i64
  (ct.expr-list-length items)
  (ct.expr-int 42))

(defmacro (three [value : Expr]) : i64
  (ct.expr-int 11)
  (ct.expr-int 22)
  value)

(defmacro (single [value : Expr]) : i64
  value)