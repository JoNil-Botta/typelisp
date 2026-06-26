;: SPEC safe-code contract: dynamic-array bounds traps instead of performing
;: invalid memory access.
(import stdlib.array)

(define (main) : i64
  (let
    [a : (Array i64) (array.make-array i64 1)]
    (array.array-ref a 1)))