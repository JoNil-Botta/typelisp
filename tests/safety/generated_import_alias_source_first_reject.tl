(import decls_generated_conflict_left as dep)

(defmacro (emit-conflict) : Decls
  `(begin
    (cfg linux (import decls_generated_conflict_right as dep))
    (cfg windows (import decls_generated_conflict_right as dep))))

(emit-conflict)

(define (main) : i64
  42)