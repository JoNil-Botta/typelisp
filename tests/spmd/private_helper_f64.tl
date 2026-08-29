;; Out-of-line direct SPMD helper call with a varying f64 argument/result.
(define (heavy-f64 [x : f64]) : f64
  (+ (+ (+ (+ (+ (+ (+ x 1.0) 2.0) 3.0) 4.0) 5.0) 6.0) 7.0))

(define (fill
  [xs : (& xs (__tl_dyn-array f64))]
  [out : (&mut out (__tl_dyn-array f64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (heavy-f64 (array-ref xs i)))))

(define (sum-array [xs : (& xs (__tl_dyn-array f64))] [n : i64]) : f64
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
          (set! (array-ref xs i) (cast i : f64))
          (set! i (+ i 1))))
      (fill (& xs) (&mut out) n)
      (if (= (sum-array (& out) n) 442.0)
        42
        1))))