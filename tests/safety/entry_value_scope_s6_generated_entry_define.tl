;; #9687: a macro-generated entry define.
(import entry_value_scope_s6_generated_entry_define_ngd)

(defmacro (gen-def) : Decls
  `(define (gen-helper) : i64
    5))

(gen-def)

(define (main) : i64
  (entry_value_scope_s6_generated_entry_define_ngd.n-gd))