(defmacro (emit-conflicting-imports) : Module
  `(begin
    (module generated.unqualified_conflict)
    (import decls_generated_conflict_left.answer as value)
    (import decls_generated_conflict_right.answer as value)))

(import (emit-conflicting-imports) as generated)

(define (main) : i64
  42)