(import stdlib.io)

;; FORCING TEST for M-G3 stage 2 (frame-pointer omission + %rbp as the 6th
;; callee-saved pool register). Mirrors callregion_split's PRE-stage-2 shape:
;; the churn6 loop keeps SIX values live across the probe6() call each
;; iteration -- acc, i, a, b, c (hot: >= 4 refs/iteration) and v (3 uses in
;; the call-free stretch). Under the OLD 5-CSR pool the coldest value v loses
;; the competition and spills (the M-G2b region rescue then serves it with ONE
;; caller-saved entry reload per iteration = one frame read in the loop).
;; With %rbp as the 6th CSR all six values get callee-saved homes: the loop
;; body contains ZERO frame reads, v lives in %rbp (asserted via the imul
;; operands), and the function is frame-pointer-free (no `pushq %rbp`
;; prologue; `subq $frame+8, %rsp` instead).
;;
;; target/rbp-csr-gate.sh asserts run=42 + zero loop frame reads + %rbp used
;; as an imul operand + no pushq %rbp in churn6 (FAILS pre-stage-2 with one
;; region-split entry reload per iteration: proven forcing).
;; Recursive on purpose so the leaf inliner cannot delete the call: probe6(x) = x.
(define (probe6 [x : i64]) : i64
  (if (<= x 0)
    0
    (+ 1 (probe6 (- x 1)))))

;; NON-TAIL self-recursion (never taken at rounds = 1) keeps churn6 out of the
;; inliner AND out of opt-tailrec, so the gate can assert on the named
;; function's loop body.
(define (churn6 [v : i64] [rounds : i64]) : i64
  (let
    [a : i64 1]
    [b : i64 2]
    [c : i64 3]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i 100)
        (begin
          (set! acc (+ acc (probe6 i)))
          ; the call every value spans
          (set! acc (+ acc (+ a i)))
          ; a,b,c stay hot (4-5 refs each)
          (set! acc (+ acc (* 2 a)))
          (set! a (+ a 1))
          (set! acc (+ acc (+ b i)))
          (set! acc (+ acc (* 2 b)))
          (set! b (+ b 1))
          (set! acc (+ acc (+ c i)))
          (set! acc (+ acc (* 2 c)))
          (set! c (+ c 1))
          (set! acc (+ acc (* v i)))
          ; v: 3 uses, all multiplies
          (set! acc (+ acc (* v a)))
          (set! acc (+ acc (* v b)))
          (set! i (+ i 1))))
      (let
        [r : i64 (+ acc (+ a (+ b (+ c v))))]
        (if (> rounds 1)
          (+ r (churn6 v (- rounds 1)))
          r)))))

(define (main) : i64
  (let
    ;; v = 10 when run without args (io.arg-count = 1); (io.arg-count) blocks
    ;; constant folding of the whole loop.
    [v : i64 (+ 9 (io.arg-count))]
    [r : i64 (churn6 v 1)]
    ;; per iteration t (0..99, a_t = 1+t, b_t = 2+t, c_t = 3+t, probe6(t) = t):
    ;;   t + (1+2t) + (2+2t) + (2+2t) + (4+2t) + (3+2t) + (6+2t)
    ;;     + 10t + 10(2+t) + 10(3+t)
    ;; acc = 219650; finals a=101 b=102 c=103 v=10 -> r = 219966.
    (if (= r 219966)
      42
      1)))
