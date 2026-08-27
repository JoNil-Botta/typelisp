(import stdlib.format)

(define (main) : i64
  (let
    [rendered : String (format.format "{:E}" 'x')]
    (cast (string-length rendered) : i64)))