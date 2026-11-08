;; #9687: a function, seen from an imported module.
(import entry_value_scope_p01_fn_nf)

(define (helper) : i64
  41)

(define (main) : i64
  (entry_value_scope_p01_fn_nf.n-fn))