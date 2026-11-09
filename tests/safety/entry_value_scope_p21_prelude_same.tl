;; #9687: a name spelled like a runtime function, same type, seen from an imported module.
(import entry_value_scope_p21_prelude_same_n)

(define (int-to-string [v : i64]) : String
  "x")

(define (main) : i64
  (entry_value_scope_p21_prelude_same_n.n-prel3))