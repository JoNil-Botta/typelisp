(defmacro (emit-conflicting-imports) : Decls
  `(begin
    (import decls_generated_conflict_left.answer as value)
    (import decls_generated_conflict_right.answer as value)))

(emit-conflicting-imports)

(define (main) : i64
  42)