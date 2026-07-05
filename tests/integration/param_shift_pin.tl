(import stdlib.io)

;; FORCING TEST for GAP3a: shift-by-CONSTANT is not a param-pin clobber point.
;;
;; `shift-mix` is a zero-call scalar leaf whose only would-be clobber points are
;; shifts by immediate constants (`shr acc 1`, `shl i 2` -- both emitted as
;; `s{h,a}{r,l}q $imm, reg`, which never reads or writes %rcx/%cl). Pre-GAP3a
;; the pin gate's clobber classification counted EVERY shift, so the whole
;; function was treated as clobber-having and params a/n lost their ABI pins:
;; two entry copies into callee-saved registers plus two CSR pushes. Post-GAP3a
;; the function is clobber-point-free and a keeps %rdi, n keeps %rsi, with NO
;; entry copies and NO callee-saved saves. target/shift-pin-gate.sh asserts the
;; asm shape and FAILS on the pre-GAP3a compiler at the entry-copy/CSR check.
;;
;; `shift-mix` must stay OUTLINED (the pin contract is per-function): recursion
;; would add a call = a real clobber point, so instead the never-taken `poke`
;; branch takes `shift-mix` as a function VALUE -- address-taken functions are
;; excluded from every inline path (opt-inline-census-address-taken?). The
;; data-dependent loop-carried `shr acc 1` cannot be strength-reduced away, so
;; a constant shift provably survives into the emitted body.
(define (shift-mix [a : i64] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 a]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (shr acc 1)))
          (set! acc (bit-and acc 1023))
          (set! acc (+ acc (shl i 2)))
          (set! acc (+ acc a))
          (set! i (+ i 1))))
      (+ acc n))))

;; Never executed (n < 100 always); its only job is to take shift-mix's
;; address so no inliner path may absorb it.
(define (poke [f : (-> i64 i64 i64)] [a : i64] [n : i64]) : i64
  (f a n))

(define (main) : i64
  (let
    ;; no CLI args: arg-count = 1 (program name), so a = 5, n = 4.
    ;; i=0: acc=5  -> +2 =7   -> &1023 =7   -> +0  =7   -> +5 =12
    ;; i=1: acc=12 -> +6 =18  -> 18          -> +4  =22  -> +5 =27
    ;; i=2: acc=27 -> +13=40  -> 40          -> +8  =48  -> +5 =53
    ;; i=3: acc=53 -> +26=79  -> 79          -> +12 =91  -> +5 =96
    ;; result = 96 + n = 100
    [a : i64 (+ (io.arg-count) 4)]
    [n : i64 (+ (io.arg-count) 3)]
    [r : i64
      (if (> n 100)
        (poke shift-mix a n)
        (shift-mix a n))]
    (if (= r 100)
      42
      1)))