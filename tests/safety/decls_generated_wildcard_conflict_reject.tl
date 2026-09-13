(defmacro (emit-conflicting-imports) : Decls
  `(begin
    (import decls_generated_conflict_left.*)
    (import decls_generated_conflict_right.*)))

(emit-conflicting-imports)

(define (main) : i64
  42)