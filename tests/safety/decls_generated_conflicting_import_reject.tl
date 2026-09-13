;; Generated imports must obey the ordinary alias-collision rule even when
;; their bindings are unused.
(defmacro (emit-conflicting-imports) : Decls
  `(begin
    (import decls_generated_conflict_left as dep)
    (import decls_generated_conflict_right as dep)))

(emit-conflicting-imports)

(define (main) : i64
  42)