(module semantic.index.macro_dep)

;: Imported macro documentation.
(defmacro (imported-wrap [value : Expr]) : Expr
  `(+ ,value 2))