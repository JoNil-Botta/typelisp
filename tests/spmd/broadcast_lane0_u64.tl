;; SPMD broadcast corpus (#3006): u64 lane 0 broadcast is backend-observable.
;; n = 14 gives AVX2 a two-lane tail and AVX-512 a six-lane tail.
; Compatibility exception for #3772: SPMD value operands still use bare
; array-ref so the checker sees the compiler array-read AST.
(define (init [xs : (&mut xs (__tl_dyn-array u64))] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref xs i) (cast (+ i 1) : u64))
        (set! i (+ i 1))))))

(define (fill
  [xs : (& xs (__tl_dyn-array u64))]
  [out : (&mut out (__tl_dyn-array u64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (spmd-broadcast (array-ref xs i) 0))))

(define (checksum [out : (& out (__tl_dyn-array u64))] [n : i64]) : i64
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
    [n : i64 14]
    [xs : (__tl_dyn-array u64) (__tl_make-array u64 n)]
    [out : (__tl_dyn-array u64) (__tl_make-array u64 n)]
    (begin
      (init (&mut xs) n)
      (fill (& xs) (&mut out) n)
      (bit-and (checksum (& out) n) 0xff))))