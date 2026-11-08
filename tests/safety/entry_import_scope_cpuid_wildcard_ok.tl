;; An entry-module wildcard import of a `cpuid` definition binds it only in the
;; entry module (#9678): the user module keeps the default-environment builtin.
;; The two builtin reads cancel, leaving the import's 42.
(import entry_import_scope_cpuid_user)
(import entry_import_scope_cpuid_dep.*)

(define (main) : i64
  (-
    (+ (cpuid) (entry_import_scope_cpuid_user.user-leaf))
    (entry_import_scope_cpuid_user.user-leaf)))