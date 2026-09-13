;; An unused import from a Decls macro is still required to resolve.
(defmacro (emit-missing-import) : Decls
  `(import nonexistent_decls_generated_dependency))

(emit-missing-import)

(define (main) : i64
  42)