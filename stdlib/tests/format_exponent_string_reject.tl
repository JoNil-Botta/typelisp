(import stdlib.format)

(define (main) : i64
  (let
    [rendered : String (format.format "{:e}" "text")]
    (cast (string-length rendered) : i64)))