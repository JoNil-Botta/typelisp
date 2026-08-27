;; SPMD uniform zip corpus (#2561): i64 foreach body
;; `out[i] = a[i] * b[i] + c[i] + r` with uniform scalar `r`.
;; The length forces both full-vector and tail paths under avx2/avx512.
(define (init
  [a : (__tl_dyn-array i64)]
  [b : (__tl_dyn-array i64)]
  [c : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref a i) (+ i 1))
        (set! (array-ref b i) (+ (* i 2) 3))
        (set! (array-ref c i) (+ (* i 3) 7))
        (set! i (+ i 1))))))

(define (fill
  [a : (__tl_dyn-array i64)]
  [b : (__tl_dyn-array i64)]
  [c : (__tl_dyn-array i64)]
  [out : (__tl_dyn-array i64)]
  [n : i64]
  [r : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set!
      (array-ref out i)
      (+ (+ (* (array-ref a i) (array-ref b i)) (array-ref c i)) r))))

(define (checksum [out : (__tl_dyn-array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref out i)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 13]
    [a : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [b : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [c : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    (begin
      (init a b c n)
      (fill a b c out n 5)
      (bit-and (checksum out n) 0xff))))