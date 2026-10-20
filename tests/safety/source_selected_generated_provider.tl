;; Provider for the `source_selected_generated_*` rows: its only export is
;; emitted by a module-scope declaration macro.
(defmacro (emit-answer) : Decls
  `(begin
    (define answer : i64
      42)
    (defmacro (generated-answer) : Expr
      `42)))

(emit-answer)