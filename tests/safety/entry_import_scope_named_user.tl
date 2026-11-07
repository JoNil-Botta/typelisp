;; Helper for entry_import_scope_builtin_ok: a named module's own wildcard
;; import stays visible inside that module.
(import entry_import_scope_dep.*)

(define (user-value) : i64
  (helper))