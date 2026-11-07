;; An entry module's selected-item alias `h` is local to the entry module
;; (#9678).
(import entry_import_scope_alias_user)
(import entry_import_scope_dep.helper as h)

(define (main) : i64
  (+ (entry_import_scope_alias_user.user-value) (h)))