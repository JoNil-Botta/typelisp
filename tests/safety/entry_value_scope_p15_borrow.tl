;; #9687: a borrow of a global, seen from an imported module.
(import entry_value_scope_p15_borrow_nbor)

(define counter : i64
  15)

(define (main) : i64
  (entry_value_scope_p15_borrow_nbor.n-bor))