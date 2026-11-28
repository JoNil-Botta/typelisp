(cfg
  direct-macro
  (defmacro (generated-seven) : Expr
    `7))

(cfg
  (not direct-macro)
  (defmacro (emit-inner) : Decls
    `(defmacro (generated-seven) : Expr
      `7)))

(cfg
  (not direct-macro)
  (defmacro (emit-outer) : Decls
    `(emit-inner)))

(cfg (not direct-macro) (emit-outer))