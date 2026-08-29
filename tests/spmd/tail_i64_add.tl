;; SPMD SIMD-tail corpus (#1149): `foreach` elementwise add over a length that
;; is NOT a multiple of any i64 vector width (13 vs 4/8), forcing a scalar/masked
;; tail. The `foreach` is SIMD-lowered under avx2/avx512; `main` returns a value
;; derived from EVERY lane (a full-array checksum) so a mishandled tail changes
;; the result. The comparison harness builds this at scalar/avx2/avx512 and
;; asserts identical exit codes. a[i]=i+1, b[i]=2i, out[i]=3i+1; the n=13
;; checksum is 247, so every mode must exit 247.
(define (init
  [a : (&mut a (__tl_dyn-array i64))]
  [b : (&mut b (__tl_dyn-array i64))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref a i) (+ i 1))
        (set! (array-ref b i) (* i 2))
        (set! i (+ i 1))))))

(define (fill
  [a : (& a (__tl_dyn-array i64))]
  [b : (& b (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (array-ref a i) (array-ref b i)))))

(define (checksum [out : (& out (__tl_dyn-array i64))] [n : i64]) : i64
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
    [out : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    (begin
      (init (&mut a) (&mut b) n)
      (fill (& a) (& b) (&mut out) n)
      (bit-and (checksum (& out) n) 0xff))))