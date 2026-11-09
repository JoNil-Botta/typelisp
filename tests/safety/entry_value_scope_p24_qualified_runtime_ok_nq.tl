;; Helper for entry_value_scope_p24_qualified_runtime_ok (#9687).
(import stdlib.runtime)

(define (n-q) : i64
  (let
    [s : String (runtime.int-to-string 5)]
    24))