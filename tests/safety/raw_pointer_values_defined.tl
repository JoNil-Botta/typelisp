;: SPEC safe-code contract: safe code may construct and null-test raw pointer
;: values without dereferencing them.
(define (main) : i64
  (if (ptr-null? (ptr-null : (Ptr i64)))
    42
    1))