;; #9687: a function defined after main, seen from an imported module.
(import entry_value_scope_p18_later_nf)

(define (main) : i64
  (entry_value_scope_p18_later_nf.n-fn))

(define (helper) : i64
  18)