;; Helper for entry_value_scope_c3_xgetbv_entry_builtin_kept (#9687).
(define (n-xg) : i64
  (if (= (bit-and (xgetbv 0) 1) 1)
    42
    41))