(import stdlib.io)

;; FORCING TEST for GAP3b: handle-typed params are pinnable to their incoming
;; ABI register.
;;
;; `sum-arr` is a zero-clobber leaf (bounds checks are not clobber points): its
;; scalar param n already pins %rsi, but pre-GAP3b the pin gate demanded a true
;; scalar type (compiler-reg-integer-param-type? = scalar-type?), so the Array
;; handle xs -- an 8-byte descriptor pointer that is pin-identical to a scalar
;; (M-A2/M-C2 made handles ordinary GP values) -- was only a greedy candidate:
;; one entry copy `movq %rdi, %rCSR` plus a callee-saved push/pop pair.
;; Post-GAP3b xs keeps %rdi in place: NO entry copies, NO callee-saved saves in
;; the whole function. target/handle-pin-gate.sh asserts that asm shape and
;; FAILS on the pre-GAP3b compiler at the entry-copy/CSR check.
;;
;; The never-taken `poke` branch takes sum-arr's address so no inline path may
;; absorb it (a call inside sum-arr would be a real clobber point).
(define (sum-arr [xs : (Array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref xs i)))
          (set! acc (+ acc n))
          (set! i (+ i 1))))
      acc)))

;; Never executed (n < 100 always); its only job is to take sum-arr's address.
(define (poke [f : (-> (Array i64) i64 i64)] [xs : (Array i64)] [n : i64]) : i64
  (f xs n))

(define (main) : i64
  (let
    ;; no CLI args: arg-count = 1 (program name), so n = 4.
    [n : i64 (+ (io.arg-count) 3)]
    [xs : (Array i64) (make-array i64 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (* i 3))
          (set! i (+ i 1))))
      (let
        [r : i64
          (if (> n 100)
            (poke sum-arr xs n)
            (sum-arr xs n))]
        ;; array sum = 3*(0+1+2+3) = 18; n added per iteration = 16. total 34.
        (if (= r 34)
          42
          1)))))