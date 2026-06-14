;; Direct source-known SPMD helper calls with varying i64 lane arguments.
(define (bump [x : i64]) : i64
  (+ x 5))

(define (fill-inline [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! out i (bump (array-ref xs i)))))

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
    [n : i64 1]
    [xs : (Array i64) (make-array i64 n)]
    [out : (Array i64) (make-array i64 n)]
    (begin
      (array-set! xs 0 37)
      (fill-inline xs out n)
      (if (= (sum-array out n) 42)
        42
        1))))