;: The public operation is fixed-array-only; vector internals own the private
;: compatibility dynamic-array liveness protocol.
(define (take-dynamic [items : (__tl_dyn-array i64)]) : i64
  (array-take! items 0))

(define (main) : i64
  42)