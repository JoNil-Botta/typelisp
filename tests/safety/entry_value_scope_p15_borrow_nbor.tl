;; Helper for entry_value_scope_p15_borrow (#9687).
(define (n-bor) : i64
  (deref (& counter)))