(import stdlib.format)

(define (main) : i64
  (let
    [value : bool true]
    (format.format "{:b}" (& value))
    42))