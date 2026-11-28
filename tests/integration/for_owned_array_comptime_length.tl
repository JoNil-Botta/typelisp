(import stdlib.iterator)

(define (sum-row [comptime n : i64]) : i64
  (let
    [items : (Array (Array i64 3) 1) (array (array 10 20 12))]
    [total : i64 0]
    (for [row : (Array i64 n) items]
      (set! total (+ total (array-ref row 0))))
    total))

(define (sum-literal-row) : i64
  (let
    [items : (Array (Array i64 3) 1) (array (array 10 20 12))]
    [total : i64 0]
    (for [row : (Array i64 3) items]
      (set! total (+ total (array-ref row 0))))
    total))

(define (sum-protocol) : i64
  (let
    [total : i64 0]
    (for [item : i64 (iterator.range 4 7)]
      (set! total (+ total item)))
    total))

(define (main) : i64
  (if (and (= (sum-literal-row) 10) (= (sum-protocol) 15))
    (sum-row 3)
    1))