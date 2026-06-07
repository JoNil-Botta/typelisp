;; SPMD SIMD-tail corpus (#1149): `foreach` elementwise add over `i32` lanes
;; with a length (7) below any i32 vector width (8/16), so the whole loop is a
;; masked/scalar tail. Exercises a different element width than the i64 tail
;; case. a[i]=i+1, b[i]=3i, out[i]=4i+1; the n=7 checksum is 91, so scalar,
;; avx2, and avx512 builds must all exit 91.
(define (init [a : (Array i32)] [b : (Array i32)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a i (cast (+ i 1) : i32))
        (array-set! b i (cast (* i 3) : i32))
        (set! i (+ i 1))))))

(define (fill [a : (Array i32)] [b : (Array i32)] [out : (Array i32)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))

(define (checksum [out : (Array i32)] [n : i64]) : i64
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
    [a : (Array i32) (make-array i32 n)]
    [b : (Array i32) (make-array i32 n)]
    [out : (Array i32) (make-array i32 n)]
    (begin
      (init a b n)
      (fill a b out n)
      (bit-and (checksum out n) 0xff))))