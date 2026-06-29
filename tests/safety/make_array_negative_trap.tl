;: SPEC safe-code contract: generated collection lengths reject invalid
;: allocation through the bounds-check abort path.
(import stdlib.array)

(define (main) : i64
  (let
    [a : (Array i64) (array.make-array i64 -1)]
    (array-length a)))