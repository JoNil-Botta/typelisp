(import stdlib.clone)
(import stdlib.string)

(define (choose [flag : bool] [left : String] [right : String]) : i64
  (let
    [copy : String
      (clone.deep
        (if flag
          left
          right))]
    (+ (string.string-length copy) (string.string-length left))))