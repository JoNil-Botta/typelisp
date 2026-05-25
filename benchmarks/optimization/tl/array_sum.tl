(define (fill [xs : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! xs i (% (+ (* i 13) 5) 97))
        (set! i (+ i 1))))))

(define (sum-array [xs : (Array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref xs i)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string->int (arg 1))]
    [xs : (Array i64) (make-array i64 (string->int (arg 1)))]
    (begin
      (fill xs n)
      (print (sum-array xs n))
      0)))