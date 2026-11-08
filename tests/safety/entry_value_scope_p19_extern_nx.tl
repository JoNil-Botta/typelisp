;; Helper for entry_value_scope_p19_extern (#9687).
(define (n-x) : i64
  (if (> (cast (getpid) : i64) 0)
    19
    0))