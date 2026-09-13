;; Decls-generated imports must load before ordinary typechecking. Repeated
;; generation reuses its identity without dropping aliases or loading twice.
(defmacro (emit-imports) : Decls
  `(begin
    (import decls_generated_import_dep as first)
    (import decls_generated_import_dep as second)
    (import decls_generated_import_empty)
    (import decls_generated_import_dep.answer as selected)
    (import decls_generated_import_dep.answer as selected)
    (import decls_generated_import_dep.*)
    (import decls_generated_import_macro_dep.answer as late)
    (cfg linux (import decls_generated_import_dep as platform))
    (cfg windows (import decls_generated_import_dep as platform))
    (cfg
      (all (not linux) (not windows))
      (import nonexistent_inactive_decls_dependency))))

(emit-imports)

(emit-imports)

(define (main) : i64
  (if (= (+ late (+ selected answer)) 42)
    (+ first.answer (+ second.answer platform.answer))
    0))