;; Helper for the entry_import_scope_cpuid_* fixtures (#9678): definitions an
;; entry module imports under the default-environment builtin spelling `cpuid`.
(define (cpuid) : i64
  42)

(define (answer) : i64
  42)