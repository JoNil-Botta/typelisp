(defmacro (emit-conflicting-imports) : Module
  `(begin
    (module generated.conflicting_imports)
    (import decls_generated_conflict_left as dep)
    (import decls_generated_conflict_right as dep)
    (define answer : i64
      42)))

(import (emit-conflicting-imports) as generated)

(define (main) : i64
  generated.answer)