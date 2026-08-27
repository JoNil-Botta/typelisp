;: SPEC safe-code contract: dynamic-array bounds traps instead of performing
;: invalid memory access.

(define (main) : i64
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (array-ref a 1)))