(define (bump [value : i64]) : i64
  (+ value 1))

(define (compose [value : i64]) : i64
  (bump value))

(define (combine [left : i64] [right : i64]) : i64
  (+ (bump left) (bump right)))