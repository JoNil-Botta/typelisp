;; #9687: a qualified runtime call beside an entry define, seen from an imported module.
(import entry_value_scope_p24_qualified_runtime_ok_nq)

(define (int-to-string [v : i64]) : i64
  77)

(define (main) : i64
  (+
    (entry_value_scope_p24_qualified_runtime_ok_nq.n-q)
    (- (int-to-string 1) 77)))