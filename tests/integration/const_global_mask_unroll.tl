(import stdlib.array)

;; Regression guard for #5238: a checked counted loop whose array index is
;; masked by an immutable *global* must reach the same BCE-versioned, x16
;; unrolled fast path as one that spells the mask as a literal.
;;
;; The optimizer proves `mask-global` constant and substitutes the literal into
;; the operand before the fold/loop cluster runs (src/compiler_optimize.tl, the
;; early `opt-const-divisor-rewrite-summary-blocks` call). Without that
;; ordering, iteration 1 cannot derive the masked BCE guard, iteration 2 spends
;; itself creating the fast clone, and the two-iteration fixpoint cap
;; (`optimize-function-max-iterations`) leaves the clone un-unrolled -- the
;; `benchmarks/opt_crc32` shape, which was 495,577,856 instructions before the
;; fix and 325,169,904 after.
;;
;; scripts/verify-asm-shape-gates.sh asserts `__bce_fast__unroll_body` in
;; `mask-sum`. The literal-mask twin below is the control: both must unroll, so
;; a regression that loses the global-mask path shows up as an asymmetry rather
;; than as a silently slower binary.
;;
;; Soundness note: `mask-global` is immutable, non-zero, literal and imm32, so
;; it is exactly the case the substitution table admits. Mutable,
;; address-taken, zero, non-literal and non-imm32 globals are excluded by that
;; table and are covered by the optimizer's own self-tests.
(define mask-global : i64
  255)

;; Masked index from a global mask: the shape that regressed.
(define (mask-sum [table : (__tl_dyn-array i64)] [buf : (__tl_dyn-array u8)] [len : i64]) : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (let
            [byte : i64 (cast (array-ref buf i) : i64)]
            [index : i64 (bit-and (bit-xor acc byte) mask-global)]
            (set! acc (bit-xor (shr acc 8) (array-ref table index))))
          (set! i (+ i 1))))
      acc)))

;; Literal-mask control: identical but for the mask spelling.
(define (mask-sum-literal [table : (__tl_dyn-array i64)] [buf : (__tl_dyn-array u8)] [len : i64]) : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (let
            [byte : i64 (cast (array-ref buf i) : i64)]
            [index : i64 (bit-and (bit-xor acc byte) 255)]
            (set! acc (bit-xor (shr acc 8) (array-ref table index))))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [table : (__tl_dyn-array i64) (array.make-array i64 256)]
    [buf : (__tl_dyn-array u8) (array.make-array u8 64)]
    [n : i64 0]
    (begin
      (while (< n 256)
        (begin
          (array-set! table n (+ (* n 2654435761) 17))
          (set! n (+ n 1))))
      (set! n 0)
      (while (< n 64)
        (begin
          (array-set! buf n (cast (bit-and (+ (* n 167) 13) 255) : u8))
          (set! n (+ n 1))))
      ;; Both spellings must agree; a mis-versioned fast clone that dropped or
      ;; mis-ordered the mask would diverge here rather than only run slower.
      (if (= (mask-sum table buf 64) (mask-sum-literal table buf 64))
        0
        1))))