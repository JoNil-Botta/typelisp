;; Out-of-line direct SPMD helper call with a varying bool result.
(import stdlib.array)

(define (large-enough? [x : i64]) : bool
  (> (+ (+ (+ (+ (+ (+ (+ x 1) 2) 3) 4) 5) 6) 7) 30))

(define (fill [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (large-enough? i)
      (array-set! out i 1)
      (array-set! out i 0))))

(define (sum-array [xs : (Array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! sum (+ sum (array-ref xs i)))
          (set! i (+ i 1))))
      sum)))

(define (main) : i64
  (let
    [n : i64 13]
    [out : (Array i64) (array.make-array i64 n)]
    (begin
      (fill out n)
      (if (= (sum-array out n) 10)
        42
        1))))