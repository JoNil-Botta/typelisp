;; Incoming masks guard stores in an out-of-line unit helper.
(import stdlib.array)

(define (heavy-store [out : (Array i64)] [i : i64]) : unit
  (array-set! out i (+ (+ (+ (+ (+ (+ (+ i 1) 2) 3) 4) 5) 6) 7)))

(define (fill [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< i 5)
      (heavy-store out i)
      unit)))

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
    [out : (Array i64) (array.make-array i64 13)]
    (begin
      (fill out 13)
      (if (= (sum-array out 13) 150)
        42
        1))))