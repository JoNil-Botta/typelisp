;; #9687: an empty name from syntax inspection given to module-hook.
(import entry_value_scope_r3_forged_name_hook_nz)

(define (helper) : i64
  33)

(define (main) : i64
  (entry_value_scope_r3_forged_name_hook_nz.n-root))