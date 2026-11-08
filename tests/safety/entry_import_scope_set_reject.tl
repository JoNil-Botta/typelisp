;; An imported module cannot assign a global the entry module imports
;; unqualified (#9678): the name is unbound there.
(import entry_import_scope_set_user)
(import entry_import_scope_dep.*)

(define (main) : i64
  (+ (entry_import_scope_set_user.user-reset) limit))