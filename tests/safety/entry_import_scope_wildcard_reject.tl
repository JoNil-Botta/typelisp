;; An entry module's wildcard import binds names only in the entry module
;; (#9678): entry_import_scope_user cannot call `helper` without importing it.
(import entry_import_scope_user)
(import entry_import_scope_dep.*)

(define (main) : i64
  (+ (entry_import_scope_user.user-value) (helper)))