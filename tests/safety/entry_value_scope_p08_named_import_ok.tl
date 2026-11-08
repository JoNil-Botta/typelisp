;; #9687: the module's own import colliding with an entry name, seen from an imported module.
(import entry_value_scope_p08_named_import_ok_nimp)

(define (helper) : i64
  1)

(define (main) : i64
  (entry_value_scope_p08_named_import_ok_nimp.n-imp))