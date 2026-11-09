;; Helper for entry_value_scope_p04_structctor (#9687).
(define (n-struct) : i64
  (let
    [f (Foo 5)]
    f.x))