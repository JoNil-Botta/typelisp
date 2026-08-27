(import stdlib.format)

(define (main) : i64
  (let
    [rendered : String (format.format "{:e}" true)]
    (cast (string-length rendered) : i64)))