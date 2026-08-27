(import stdlib.format)

(define (main) : i64
  (let
    [pointer : (Ptr i64) (ptr-null : (Ptr i64))]
    [rendered : String (format.format "{:e}" pointer)]
    (cast (string-length rendered) : i64)))