;; #9687: a fresh empty name given to module-hook.
(import entry_value_scope_r5_fresh_name_hook_nz)

(define (helper) : i64
  33)

(define (main) : i64
  (entry_value_scope_r5_fresh_name_hook_nz.n-root))