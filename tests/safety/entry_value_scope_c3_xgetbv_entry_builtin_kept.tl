;; #9687: the xgetbv builtin beside an entry define, seen from an imported module.
(import entry_value_scope_c3_xgetbv_entry_builtin_kept_n)

(define (xgetbv [a : i64]) : i64
  8)

(define (main) : i64
  (entry_value_scope_c3_xgetbv_entry_builtin_kept_n.n-xg))