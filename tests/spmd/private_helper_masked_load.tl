;; Incoming masks guard helper bounds checks and loads in masked/tail lanes.
(define (heavy-load [xs : (& xs (__tl_dyn-array i64))] [i : i64]) : i64
  (+ (+ (+ (+ (+ (+ (+ (array-ref xs i) 1) 2) 3) 4) 5) 6) 7))

(define (fill
  [xs : (& xs (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< i 5)
      (set! (array-ref out i) (heavy-load xs i))
      (set! (array-ref out i) 0))))

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
    [n : i64 13]
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref xs i) i)
          (set! i (+ i 1))))
      (fill (& xs) (&mut out) n)
      (if (= (sum-array (& out) n) 150)
        42
        1))))