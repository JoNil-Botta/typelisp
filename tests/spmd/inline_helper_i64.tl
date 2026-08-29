;; Direct source-known SPMD helper calls with varying i64 lane arguments.
(define (bump [x : i64]) : i64
  (+ x 5))

(define (fill-inline
  [xs : (& xs (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref out i) (bump (array-ref xs i)))))

(define (sum-array [xs : (& xs (__tl_dyn-array i64))] [n : i64]) : i64
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
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    (begin
      (set! (array-ref xs 0) 37)
      (fill-inline (& xs) (&mut out) n)
      (if (= (sum-array (& out) n) 42)
        42
        1))))