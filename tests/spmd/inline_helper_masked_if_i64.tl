;; Direct source-known helper calls inside AVX-512 masked SPMD branches.
(define (init-xs [xs : (Array i64)]) : unit
  (begin
    (array-set! xs 0 -3)
    (array-set! xs 1 4)
    (array-set! xs 2 -1)
    (array-set! xs 3 0)
    (array-set! xs 4 7)
    (array-set! xs 5 -8)
    (array-set! xs 6 2)
    (array-set! xs 7 9)
    (array-set! xs 8 -5)
    (array-set! xs 9 1)
    (array-set! xs 10 6)
    (array-set! xs 11 -2)
    (array-set! xs 12 3)))

(define (bump [x : i64]) : i64
  (+ x 5))

(define (non-negative? [x : i64]) : bool
  (>= x 0))

(define (fill-inline [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (non-negative? (array-ref xs i))
      (array-set! out i (bump (array-ref xs i)))
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
    [xs : (Array i64) (make-array i64 n)]
    [out : (Array i64) (make-array i64 n)]
    (begin
      (init-xs xs)
      (fill-inline xs out n)
      (if (= (sum-array out n) 72)
        42
        1))))