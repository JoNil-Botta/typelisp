;; #9687: an entry import beside an entry define.
(import entry_value_scope_s10_entry_import_and_define_named_reject_nb)
(import entry_value_scope_s10_entry_import_and_define_named_reject_dep.*)

(define (local-one) : i64
  1)

(define (main) : i64
  (entry_value_scope_s10_entry_import_and_define_named_reject_nb.n-b))