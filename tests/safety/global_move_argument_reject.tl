;: Ordinary by-value arguments cannot move a non-Copy global.
(define global-box : (Box i64)
  (box 42))

(define (take-box [cell : (Box i64)]) : i64
  (box-get cell))

(define (main) : i64
  (take-box
    (if true
      global-box
      (box 0))))