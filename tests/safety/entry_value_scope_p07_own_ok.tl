;; #9687: the module's own define colliding with an entry name, seen from an imported module.
(import entry_value_scope_p07_own_ok_nown)

(define (helper) : i64
  1)

(define (main) : i64
  (+ (entry_value_scope_p07_own_ok_nown.n-own) (- (helper) 1)))