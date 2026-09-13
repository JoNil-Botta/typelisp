(defmacro (emit-missing-selection) : Decls
  `(import decls_generated_conflict_left.missing as unused))

(emit-missing-selection)

(define (main) : i64
  42)