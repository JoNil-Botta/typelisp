;; SPMD broadcast corpus (#2883): lane 1 traps in scalar mode but is valid for
;; full AVX2/AVX-512 gangs over n = 8.
; Compatibility exception for #3772: SPMD value operands still use bare
; array-ref so the checker sees the compiler array-read AST.

(define (init [xs : (&mut xs (__tl_dyn-array i64))] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref xs i) (+ i 1))
        (set! i (+ i 1))))))

(define (fill
  [xs : (& xs (__tl_dyn-array i64))]
  [out : (&mut out (__tl_dyn-array i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (spmd-broadcast (array-ref xs i) 1))))

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
    [n : i64 8]
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    (begin
      (init (&mut xs) n)
      (fill (& xs) (&mut out) n)
      (bit-and (checksum (& out) n) 0xff))))