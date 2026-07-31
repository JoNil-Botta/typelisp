;: SPEC safe-code contract: dynamic-array bounds traps instead of performing
;: invalid memory access.
(import stdlib.array)

(define (main) : i64
  (let
    [a : (__tl_dyn-array i64) (array.make-array i64 1)]
    (array-ref a 1)))