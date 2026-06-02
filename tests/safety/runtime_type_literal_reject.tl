;: SPEC safe-code contract: comptime-only metadata cannot be smuggled into
;: runtime values.
(define (main) : i64
  (comptime (type i64)))