(define (sum-row [n : i64]) : i64
  (let
    [items : (Array (Array i64 3) 1) (array (array 10 20 12))]
    [total : i64 0]
    (for [row : (Array i64 n) items]
      (set! total (+ total (array-ref row 0))))
    total))

(define (main) : i64
  (sum-row 3))