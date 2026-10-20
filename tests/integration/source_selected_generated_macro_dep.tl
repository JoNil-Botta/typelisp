;; Declaration macros imported by `source_selected_generated_dep`.
(defmacro (emit-scaled [name : Expr] [value : Expr]) : Decls
  `(define ,name : i64
    (* ,value 2)))

(defmacro (emit-inner) : Decls
  `(begin
    (define deep : i64
      5)
    (defmacro (nested-answer) : Expr
      `42)))

;; Nested generation: this generator's output is another generator call.
(defmacro (emit-outer) : Decls
  `(emit-inner))