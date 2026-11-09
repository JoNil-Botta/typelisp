;; #9687: a global, seen from an imported module.
(import entry_value_scope_p02_global_ng)

(define limit : i64
  9)

(define (main) : i64
  (entry_value_scope_p02_global_ng.n-read))