(import stdlib.clone)

(define (choose [flag : bool] [left : String] [right : String]) : String
  (clone.deep
    (if flag
      left
      right)))