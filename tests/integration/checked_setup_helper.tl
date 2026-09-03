;; REGRESSION TEST for CB-2(b): the recorded loser must stay refused.
;;
;; `build-csr` is the shape the measured tier's site-depth clause was written
;; for and the shape its own autopsy names: a SEVEN-parameter builder with a
;; loop of its own, called ONCE from the entry block of a caller that holds a
;; hot loop. Absorbing it retires one boundary per call of the caller and lays
;; the merged body's register demand on the caller's loop, which is why
;; `cfg-build-csr` into `cfg-function` cost cfg_domloops +1.085% when the flat
;; plan model admitted it -- "the tax lands on the caller's LOOPS, whose
;; register pressure the merged body raises, and the plan prices an allocation
;; once per invocation".
;;
;; The clause that refused this site never priced it. It is now offered to the
;; verdict -- the site is the caller's ENTRY block, so it runs exactly once per
;; invocation, which is the currency the plan prices in; the builder is
;; call-free, so the caller's leaf frame is the one thing the inline could still
;; win; and `main` reaches the caller through a loop -- and the verdict, a real
;; re-plan of the merged body, refuses it. `scripts/verify-asm-shape-gates.sh`
;; pins that the call survives; a fixture whose exit code alone was checked
;; could not tell the two apart, because absorbing the builder is CORRECT and
;; only slower.
(define (build-csr
  [rows : (& r (__tl_dyn-array i64))]
  [cols : (& c (__tl_dyn-array i64))]
  [n : i64]
  [m : i64]
  [base : i64]
  [stride : i64]
  [seed : i64]) : i64
  (let
    [acc : i64 seed]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (* (array-ref rows i) base)))
          (set! acc (bit-xor acc (* (array-ref cols i) stride)))
          (set! acc (+ acc m))
          (set! i (+ i 1))))
      acc)))

;; The loop-holding caller. The builder runs once, at the entry; the loop below
;; it is what an absorbed body would tax.
(define (run
  [rows : (& r (__tl_dyn-array i64))]
  [cols : (& c (__tl_dyn-array i64))]
  [n : i64]
  [m : i64]) : i64
  (let
    [seed : i64 (build-csr rows cols n m 3 5 11)]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set!
            acc
            (+
              acc
              (bit-and (+ (* (array-ref rows i) seed) (array-ref cols i)) 4095)))
          (set! i (+ i 1))))
      (+ acc (bit-and seed 255)))))

;; The builder's second reference, at a cold site: two references keep every
;; single-reference band out, so whatever decides this site is the measured
;; tier.
(define (rebuild
  [rows : (& r (__tl_dyn-array i64))]
  [cols : (& c (__tl_dyn-array i64))]
  [n : i64]) : i64
  (bit-and (build-csr rows cols n 1 1 1 0) 65535))

(define (main) : i64
  (let
    [rows : (__tl_dyn-array i64) (__tl_make-array i64 32)]
    [cols : (__tl_dyn-array i64) (__tl_make-array i64 32)]
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i 32)
        (begin
          (set! (array-ref rows i) (+ (* i 7) 3))
          (set! (array-ref cols i) (+ (* i 13) 5))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i 64)
        (begin
          (set! total (+ total (run (& rows) (& cols) 16 2)))
          (set! i (+ i 1))))
      (unless (= total 1991360) (return 1))
      (unless (= (rebuild (& rows) (& cols) 8) 336) (return 2))
      42)))