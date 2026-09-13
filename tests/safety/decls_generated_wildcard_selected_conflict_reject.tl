(defmacro (emit-conflicting-imports) : Decls
  `(begin
    (import decls_generated_conflict_left.*)
    (import decls_generated_conflict_right.answer as answer)))

(emit-conflicting-imports)

(define (main) : i64
  42)