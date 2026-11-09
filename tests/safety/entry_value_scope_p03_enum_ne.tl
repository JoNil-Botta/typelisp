;; Helper for entry_value_scope_p03_enum (#9687).
(define (n-enum) : i64
  (match Red
    [(Red) 3]
    [_ 4]))