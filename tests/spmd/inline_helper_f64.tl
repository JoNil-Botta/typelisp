;; Direct source-known SPMD helper calls with varying f64 lane arguments.
(define (scale [x : f64]) : f64
  (+ (* x 2.0) 1.0))

(define (fill-inline-f64
  [xs : (__tl_dyn-array f64)]
  [out : (__tl_dyn-array f64)]
  [n : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref out i) (scale (array-ref xs i)))))

(define (sum-array [xs : (__tl_dyn-array f64)] [n : i64]) : f64
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
    [xs : (__tl_dyn-array f64) (__tl_make-array f64 n)]
    [out : (__tl_dyn-array f64) (__tl_make-array f64 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref xs i) (cast (+ i 1) : f64))
          (set! i (+ i 1))))
      (fill-inline-f64 xs out n)
      (if (= (sum-array out n) 195.0)
        42
        1))))