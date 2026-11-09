;; #9687: a name built from text, seen from an imported module.
(import entry_value_scope_s2_text_built_named_ntext)

(define (helper) : i64
  34)

(define (main) : i64
  (entry_value_scope_s2_text_built_named_ntext.n-text))