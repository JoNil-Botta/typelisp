(defmacro (spmd-inner) : Expr
  `(foreach ([i : i64 0 0]) unit))

(defmacro (spmd-outer) : Expr
  `(spmd-inner))

(defmacro (spmd-pass [body : Expr]) : Expr
  body)