;; Incoming masks guard helper bounds checks and loads in masked/tail lanes.
(import stdlib.array)

(define (heavy-load [xs : (Array i64)] [i : i64]) : i64
  (+ (+ (+ (+ (+ (+ (+ (array-ref xs i) 1) 2) 3) 4) 5) 6) 7))

(define (fill [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< i 5)
      (array-set! out i (heavy-load xs i))
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
    [xs : (Array i64) (array.make-array i64 n)]
    [out : (Array i64) (array.make-array i64 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i i)
          (set! i (+ i 1))))
      (fill xs out n)
      (if (= (sum-array out n) 150)
        42
        1))))