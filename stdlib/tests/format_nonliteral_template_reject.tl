(import stdlib.format)

(define (main) : i64
  (let
    [template : String "value={}"]
    (format.format template 7)
    42))