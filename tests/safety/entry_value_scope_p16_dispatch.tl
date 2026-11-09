;; #9687: a defdispatch, seen from an imported module.
(import entry_value_scope_p16_dispatch_nds)

(define (show-scalar [x : i64]) : i64
  (+ x 11))

(defdispatch show (scalar show-scalar))

(define (main) : i64
  (entry_value_scope_p16_dispatch_nds.n-ds))