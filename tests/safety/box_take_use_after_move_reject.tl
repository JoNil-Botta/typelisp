(import "stdlib/string.tl")

(define (main [cell : (Box String)]) : i64
  (let
    [value : String (box-take cell)]
    (+ (string-length value) (string-length (box-get cell)))))
