(import stdlib.format)

(defstruct DisplayValue
  (value i64))

(define (to-string [_value : (& value DisplayValue)]) : String
  "value")

(define (main) : i64
  (let
    [arguments
      (let
        [value (DisplayValue 7)]
        (format.args "{}" value))]
    (begin
      (format.format arguments)
      42)))