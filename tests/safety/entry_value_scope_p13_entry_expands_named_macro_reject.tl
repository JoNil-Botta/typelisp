;; A free template name resolves where the macro is defined (SPEC 3.7.2), so an
;; imported macro does not see the entry's own `helper`.
(import entry_value_scope_p13_entry_expands_named_macro_reject_n.*)

(define (helper) : i64
  42)

(define (main) : i64
  (call-helper))