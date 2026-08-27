(import stdlib.format)

(define (main) : i64
  (let
    [precision : i64 9223372036854775807]
    [rendered : String (format.format "{0:.1$e}" (cast 1.0 : f64) precision)]
    (cast (string-length rendered) : i64)))