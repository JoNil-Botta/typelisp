;; Direct source-known helper calls inside AVX-512 masked SPMD branches.
(define (init-xs [xs : (__tl_dyn-array i64)]) : unit
  (begin
    (set! (array-ref xs 0) -3)
    (set! (array-ref xs 1) 4)
    (set! (array-ref xs 2) -1)
    (set! (array-ref xs 3) 0)
    (set! (array-ref xs 4) 7)
    (set! (array-ref xs 5) -8)
    (set! (array-ref xs 6) 2)
    (set! (array-ref xs 7) 9)
    (set! (array-ref xs 8) -5)
    (set! (array-ref xs 9) 1)
    (set! (array-ref xs 10) 6)
    (set! (array-ref xs 11) -2)
    (set! (array-ref xs 12) 3)))

(define (bump [x : i64]) : i64
  (+ x 5))

(define (non-negative? [x : i64]) : bool
  (>= x 0))

(define (fill-inline
  [xs : (__tl_dyn-array i64)]
  [out : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (non-negative? (array-ref xs i))
      (set! (array-ref out i) (bump (array-ref xs i)))
      (set! (array-ref out i) 0))))

(define (sum-array [xs : (__tl_dyn-array i64)] [n : i64]) : i64
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
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    (begin
      (init-xs xs)
      (fill-inline xs out n)
      (if (= (sum-array out n) 72)
        42
        1))))