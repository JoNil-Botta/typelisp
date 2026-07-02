(import "stdlib/io.tl")

;; FORCING TEST for M-F (loop-hoisted divmod magic constants + imm32 divisor
;; folding). Two call-free loops whose `%`/`/` by constant strength-reduce to
;; a 64-bit magic multiply:
;;
;;   * modsum:   acc = (acc*131 + i) % 1000000007 per iteration. Pre-M-F the
;;     loop body materialises TWO 64-bit constants per iteration
;;     (movabsq $-8543223828751151131 magic + movabsq $1000000007 divisor).
;;     Post-M-F the magic is loaded ONCE in the loop preheader and read from
;;     a caller-saved register, and the divisor folds into
;;     `imulq $1000000007, %rdx, r` -- the loop body contains NO movabsq.
;;   * digitsum: `% 10` and `/ 10` per iteration SHARE one hoisted magic
;;     (0x6666666666666667): one preheader movabsq, none in the body.
;;
;; target/divmagic-gate.sh asserts run=42 + zero movabsq inside each loop
;; body + exactly one movabsq per function (the preheader load). FAILS on the
;; pre-M-F compiler (2 movabsq per modsum iteration): proven forcing.

;; NON-TAIL self-recursion (never taken at rounds = 1) keeps both functions
;; out of the inliner AND out of opt-tailrec, so the gate can assert on the
;; named functions' loop bodies (rbp_sixth_csr pattern).
(define (modsum [n : i64] [rounds : i64]) : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (% (+ (* acc 131) i) 1000000007))
          (set! i (+ i 1))))
      (if (> rounds 1)
        (+ acc (modsum n (- rounds 1)))
        acc))))

(define (digitsum [n0 : i64] [rounds : i64]) : i64
  (let
    [n : i64 n0]
    [acc : i64 0]
    (begin
      (while (> n 0)
        (begin
          (set! acc (+ acc (% n 10)))
          (set! n (/ n 10))))
      (if (> rounds 1)
        (+ acc (digitsum n0 (- rounds 1)))
        acc))))

(define (main) : i64
  (let
    ;; n = 100 when run without args (arg-count = 1); (arg-count) blocks
    ;; constant folding of both loops.
    [n : i64 (+ 99 (arg-count))]
    [m : i64 (modsum n 1)]
    [d : i64 (digitsum m 1)]
    ;; acc after 100 iterations = 926242213; its digit sum = 31.
    (if (= m 926242213)
      (if (= d 31) 42 2)
      1)))
