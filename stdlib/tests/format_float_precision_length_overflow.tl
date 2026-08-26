(import stdlib.format)

(define (main) : i64
  (let
    [precision : i64 9223372036854775807]
    (begin
      (format.format "{0:.1$}" (cast 1.0 : f64) precision)
      42)))