;; #9687: a name expanded from the module's own macro, seen from an imported module.
(import entry_value_scope_p12_macro_named_nmac)

(define (helper) : i64
  12)

(define (main) : i64
  (entry_value_scope_p12_macro_named_nmac.n-mac))