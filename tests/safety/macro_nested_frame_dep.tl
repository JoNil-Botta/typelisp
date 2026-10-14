;; Macros for the macro_nested_frame_* cases: `outer` expands to a call of
;; `inner`. `inner-pointer` converts a pointer outside `unsafe`; `inner-pass`
;; only wraps its operand.
(defmacro (inner-pointer [value : Expr]) : Expr
  `(ptr->int (ptr-addr-of ,value)))

(defmacro (outer-pointer [value : Expr]) : Expr
  `(macro_nested_frame_dep.inner-pointer ,value))

(defmacro (inner-pass [value : Expr]) : Expr
  `(+ ,value 0))

(defmacro (outer-pass [value : Expr]) : Expr
  `(macro_nested_frame_dep.inner-pass ,value))