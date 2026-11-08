;; #9687: an imported macro expanded in the entry module, seen from an imported module.
(import entry_value_scope_p13_entry_expands_named_macro_ok_n.*)

(define (helper) : i64
  42)

(define (main) : i64
  (call-helper))