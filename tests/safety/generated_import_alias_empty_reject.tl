(defmacro (emit-conflicting-imports) : Decls
  `(begin
    (import generated_import_alias_empty_first as dep)
    (import generated_import_alias_empty_second as dep)))

(emit-conflicting-imports)

(define (main) : i64
  42)