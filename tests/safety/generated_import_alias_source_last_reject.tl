(defmacro (emit-conflict) : Decls
  `(import decls_generated_conflict_left as dep))

(emit-conflict)

(import decls_generated_conflict_right as dep)

(define (main) : i64
  42)