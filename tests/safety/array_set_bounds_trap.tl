;: SPEC safe-code contract: qualified fixed-array writes trap on out-of-bounds
;: indexes instead of performing invalid memory access.
(import stdlib.array)

(define (main) : i64
  (let
    [a : (Array i64 1) (array 0)]
    (begin
      (array-set! a 1 42)
      0)))