;; #9687: a macro-generated entry enum constructor.
(import entry_value_scope_s8_generated_entry_enum_variant_ngv)

(defmacro (gen-enum) : Decls
  `(defenum GenColor
    (GenRed)
    (GenBlue)))

(gen-enum)

(define (main) : i64
  (entry_value_scope_s8_generated_entry_enum_variant_ngv.n-gv))