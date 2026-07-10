(import stdlib.format)

(define (main) : i64
  (let
    [template : String "value={}"]
    (begin
      (format.format template 7)
      42)))