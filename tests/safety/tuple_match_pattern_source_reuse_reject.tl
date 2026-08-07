(import stdlib.string)

(define (main [pair : (Tuple String i64)]) : i64
  (let
    [score : i64
      (match pair
        [(tuple text number) (+ (string.string-length text) number)])]
    (+ score (tuple-ref pair 1))))