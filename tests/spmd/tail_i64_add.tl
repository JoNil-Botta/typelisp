;; SPMD SIMD-tail corpus (#1149): `foreach` elementwise add over a length that
;; is NOT a multiple of any i64 vector width (13 vs 4/8), forcing a scalar/masked
;; tail. The `foreach` is SIMD-lowered under avx2/avx512; `main` returns a value
;; derived from EVERY lane (a full-array checksum) so a mishandled tail changes
;; the result. The comparison harness builds this at scalar/avx2/avx512 and
;; asserts identical exit codes. a[i]=i+1, b[i]=2i, out[i]=3i+1; the n=13
;; checksum is 247, so every mode must exit 247.
(define (init [a : (Array i64)] [b : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a i (+ i 1))
        (array-set! b i (* i 2))
        (set! i (+ i 1))))))

(define (fill [a : (Array i64)] [b : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))

(define (checksum [out : (Array i64)] [n : i64]) : i64
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
    [a : (Array i64) (make-array i64 n)]
    [b : (Array i64) (make-array i64 n)]
    [out : (Array i64) (make-array i64 n)]
    (begin
      (init a b n)
      (fill a b out n)
      (bit-and (checksum out n) 255))))