;; The entry module's wildcard import still shadows the builtin `slice-view`
;; in the entry module, while other modules keep the builtin and a named
;; module keeps its own wildcard import (#9678): 2 + 10 + 30.
(import entry_import_scope_builtin_user)
(import entry_import_scope_named_user)
(import entry_import_scope_dep.*)

(define (main) : i64
  (+
    (entry_import_scope_builtin_user.user-count)
    (+ (slice-view 2 3 5) (entry_import_scope_named_user.user-value))))