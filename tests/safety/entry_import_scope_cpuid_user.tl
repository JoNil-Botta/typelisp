;; Helper for the entry_import_scope_cpuid_* fixtures: `cpuid` here is the
;; builtin, not the entry module's unqualified import.
(define (user-leaf) : i64
  (cast (tuple-ref (cpuid 0 0) 0) : i64))