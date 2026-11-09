;; #9687: a name spelled like a runtime function, different type, seen from an imported module.
(import entry_value_scope_p20_prelude_type_n)

(define (int-to-string [v : i64]) : i64
  77)

(define (main) : i64
  (+ (entry_value_scope_p20_prelude_type_n.n-prel2) (- (int-to-string 1) 77)))