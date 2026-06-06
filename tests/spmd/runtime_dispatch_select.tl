;; Runtime SIMD dispatch selection fixture (#1485).
;;
;; Each variant computes the same i64 SPMD checksum, then returns a distinct tag
;; so the shell harness can tell which runtime-selected body executed: scalar =
;; 42, avx2 = 106, avx512 = 170. A bad SIMD result returns a small failure code
;; instead of the tag. Keep the SPMD loop directly inside each variant while
;; sharing ordinary scalar setup/checksum helpers across all variants.
(define (dispatch_seed_a [i : i64]) : i64
  (+ i 1))

(define (dispatch_seed_b [i : i64]) : i64
  (* i 2))

(define (dispatch_fill_inputs [a : (Array i64)] [b : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! a i (dispatch_seed_a i))
        (array-set! b i (dispatch_seed_b i))
        (set! i (+ i 1))))))

(define (dispatch_checksum [out : (Array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref out i)))
          (set! i (+ i 1))))
      acc)))

(define (dispatch_scalar [n : i64]) : i64
  (let
    [a : (Array i64) (make-array i64 n)]
    [b : (Array i64) (make-array i64 n)]
    [out : (Array i64) (make-array i64 n)]
    [acc : i64 0]
    (begin
      (dispatch_fill_inputs a b n)
      (foreach
        ([i : i64 0 n])
        (array-set! out i (+ (array-ref a i) (array-ref b i))))
      (set! acc (dispatch_checksum out n))
      (if (= (bit-and acc 255) 247)
        42
        5))))

(define (dispatch_avx2 [n : i64]) : i64
  (let
    [a : (Array i64) (make-array i64 n)]
    [b : (Array i64) (make-array i64 n)]
    [out : (Array i64) (make-array i64 n)]
    [acc : i64 0]
    (begin
      (dispatch_fill_inputs a b n)
      (foreach
        ([i : i64 0 n])
        (array-set! out i (+ (array-ref a i) (array-ref b i))))
      (set! acc (dispatch_checksum out n))
      (if (= (bit-and acc 255) 247)
        106
        6))))

(define (dispatch_avx512 [n : i64]) : i64
  (let
    [a : (Array i64) (make-array i64 n)]
    [b : (Array i64) (make-array i64 n)]
    [out : (Array i64) (make-array i64 n)]
    [acc : i64 0]
    (begin
      (dispatch_fill_inputs a b n)
      (foreach
        ([i : i64 0 n])
        (array-set! out i (+ (array-ref a i) (array-ref b i))))
      (set! acc (dispatch_checksum out n))
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