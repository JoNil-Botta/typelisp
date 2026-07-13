;; Out-of-line direct SPMD helper call with a varying f64 argument/result.
(import stdlib.array)

(define (heavy-f64 [x : f64]) : f64
  (+ (+ (+ (+ (+ (+ (+ x 1.0) 2.0) 3.0) 4.0) 5.0) 6.0) 7.0))

(define (fill [xs : (Array f64)] [out : (Array f64)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! out i (heavy-f64 (array-ref xs i)))))

(define (sum-array [xs : (Array f64)] [n : i64]) : f64
  (let
    [i : i64 0]
    [sum : f64 0.0]
    (begin
      (while (< i n)
        (begin
          (set! sum (+ sum (array-ref xs i)))
          (set! i (+ i 1))))
      sum)))

(define (main) : i64
  (let
    [n : i64 13]
    [xs : (Array f64) (array.make-array f64 n)]
    [out : (Array f64) (array.make-array f64 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (cast i : f64))
          (set! i (+ i 1))))
      (fill xs out n)
      (if (= (sum-array out n) 442.0)
        42
        1))))