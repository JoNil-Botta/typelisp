;; An entry module's selected-item import binds `helper` only in the entry
;; module (#9678).
(import entry_import_scope_user)
(import entry_import_scope_dep.helper)

(define (main) : i64
  (+ (entry_import_scope_user.user-value) (helper)))