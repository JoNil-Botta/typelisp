;; Runtime SIMD dispatch selection fixture (#1485).
;;
;; Each variant computes the same i64 SPMD checksum, then returns a distinct tag
;; so the shell harness can tell which runtime-selected body executed: scalar =
;; 42, avx2 = 106, avx512 = 170. A bad SIMD result returns a small failure code
;; instead of the tag. Keep the SPMD loop directly inside each variant because
;; defdispatch lowers the variant bodies with per-ISA backend modes.
(define (dispatch_scalar [n : i64]) : i64
  (let
    [a : (Array i64) (make-array i64 n)]
    [b : (Array i64) (make-array i64 n)]
    [out : (Array i64) (make-array i64 n)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! a i (+ i 1))
          (array-set! b i (* i 2))
          (set! i (+ i 1))))
      (foreach
        ([i : i64 0 n])
        (array-set! out i (+ (array-ref a i) (array-ref b i))))
      (set! i 0)
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref out i)))
          (set! i (+ i 1))))
      (if (= (bit-and acc 255) 247)
        42
        5))))

(define (dispatch_avx2 [n : i64]) : i64
  (let
    [a : (Array i64) (make-array i64 n)]
    [b : (Array i64) (make-array i64 n)]
    [out : (Array i64) (make-array i64 n)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! a i (+ i 1))
          (array-set! b i (* i 2))
          (set! i (+ i 1))))
      (foreach
        ([i : i64 0 n])
        (array-set! out i (+ (array-ref a i) (array-ref b i))))
      (set! i 0)
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref out i)))
          (set! i (+ i 1))))
      (if (= (bit-and acc 255) 247)
        106
        6))))

(define (dispatch_avx512 [n : i64]) : i64
  (let
    [a : (Array i64) (make-array i64 n)]
    [b : (Array i64) (make-array i64 n)]
    [out : (Array i64) (make-array i64 n)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! a i (+ i 1))
          (array-set! b i (* i 2))
          (set! i (+ i 1))))
      (foreach
        ([i : i64 0 n])
        (array-set! out i (+ (array-ref a i) (array-ref b i))))
      (set! i 0)
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref out i)))
          (set! i (+ i 1))))
      (if (= (bit-and acc 255) 247)
        170
        7))))

(defdispatch
  dispatch_run
  (scalar dispatch_scalar)
  (avx2 dispatch_avx2)
  (avx512 dispatch_avx512))

(define (main) : i64
  (let
    [first : i64 (dispatch_run 13)]
    [second : i64 (dispatch_run 13)]
    (if (= first second)
      first
      250)))