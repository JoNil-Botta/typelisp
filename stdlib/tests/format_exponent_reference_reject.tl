(import stdlib.format)

(define (render [value : (& value bool)]) : String
  (format.format "{:E}" value))

(define (main) : i64
  (let
    [value : bool true]
    [rendered : String (render (& value))]
    (cast (string-length rendered) : i64)))