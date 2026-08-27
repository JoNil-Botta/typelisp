;; SPMD SIMD-tail corpus (#1149): `foreach` elementwise add over `i32` lanes
;; with a length (7) below any i32 vector width (8/16), so the whole loop is a
;; masked/scalar tail. Exercises a different element width than the i64 tail
;; case. a[i]=i+1, b[i]=3i, out[i]=4i+1; the n=7 checksum is 91, so scalar,
;; avx2, and avx512 builds must all exit 91.

(define (init
  [a : (&mut a (__tl_dyn-array i32))]
  [b : (&mut b (__tl_dyn-array i32))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref a i) (cast (+ i 1) : i32))
        (set! (array-ref b i) (cast (* i 3) : i32))
        (set! i (+ i 1))))))

(define (fill
  [a : (& a (__tl_dyn-array i32))]
  [b : (& b (__tl_dyn-array i32))]
  [out : (&mut out (__tl_dyn-array i32))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (array-ref a i) (array-ref b i)))))

(define (checksum [out : (& out (__tl_dyn-array i32))] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (cast (array-ref out i) : i64)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 7]
    [a : (__tl_dyn-array i32) (__tl_make-array i32 n)]
    [b : (__tl_dyn-array i32) (__tl_make-array i32 n)]
    [out : (__tl_dyn-array i32) (__tl_make-array i32 n)]
    (begin
      (init (&mut a) (&mut b) n)
      (fill (& a) (& b) (&mut out) n)
      (bit-and (checksum (& out) n) 0xff))))