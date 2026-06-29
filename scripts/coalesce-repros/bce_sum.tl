(import stdlib.array)
(import "stdlib/io.tl")

(define (sum-bce [xs : (Array i64)]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    [n : i64 (array-length xs)]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref xs i)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [xs : (Array i64) (array.make-array i64 5)]
    (begin
      (array-set! xs 0 10)
      (array-set! xs 1 20)
      (array-set! xs 2 30)
      (array-set! xs 3 40)
      (array-set! xs 4 50)
      (print (sum-bce xs))
      0)))