(import stdlib.io)

;; FORCING TEST for GAP1 (push-style CSR prologue saves). Two shapes:
;;
;; churn3: FOUR values (acc, i, a, v) live across the probe3() call every
;; iteration -> >= 3 callee-saved homes -> the prologue must be a pushq run
;; (r12, r13, ...) followed by ONE subq, with ZERO movq CSR saves, and every
;; epilogue must restore via popq (addq $S, %rsp; popq ...; ret).
;;
;; deeprec: NON-TAIL self-recursion (the add after the recursive call blocks
;; opt-tailrec) with a, b, c, n live ACROSS the call -> CSR saves/restores
;; exercised at every one of the 10,000 recursion levels. This is the
;; deep-recursion correctness net: an unbalanced push/pop or a mis-biased
;; frame model corrupts the return chain and cannot return 42.
;;
;; target/csr-push-gate.sh asserts run=42 + the push-run prologue + zero
;; mov-style CSR saves + pop-style epilogues (FAILS pre-GAP1 where saves are
;; `movq %rXX, N(%rsp)` and the entry is the bare `subq $(frame+8)`: proven
;; forcing).
;; Recursive on purpose so the leaf inliner cannot delete the call: probe3(x) = x.
(define (probe3 [x : i64]) : i64
  (if (<= x 0)
    0
    (+ 1 (probe3 (- x 1)))))

;; NON-TAIL self-recursion (never taken at rounds = 1) keeps churn3 out of
;; the inliner AND out of opt-tailrec, so the gate can assert on the named
;; function's prologue/epilogue.
(define (churn3 [v : i64] [rounds : i64]) : i64
  (let
    [a : i64 1]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i 50)
        (begin
          (set! acc (+ acc (probe3 i)))
          ; the call every value spans
          (set! acc (+ acc (* a i)))
          (set! a (+ a 1))
          (set! acc (+ acc (* v i)))
          (set! i (+ i 1))))
      (let
        [r : i64 (+ acc (+ a v))]
        (if (> rounds 1)
          (+ r (churn3 v (- rounds 1)))
          r)))))

;; Deep NON-tail recursion: a, b, c, n all live across the recursive call.
(define (deeprec [n : i64]) : i64
  (if (<= n 0)
    0
    (let
      [a : i64 (+ n 1)]
      [b : i64 (* n 2)]
      [c : i64 (- n 3)]
      [r : i64 (deeprec (- n 1))]
      (+ r (+ a (+ b (+ c n)))))))

(define (main) : i64
  (let
    ;; v = 10 when run without args (io.arg-count = 1); (io.arg-count) blocks
    ;; constant folding of both call trees.
    [v : i64 (+ 9 (io.arg-count))]
    [r : i64 (churn3 v 1)]
    ;; per iteration t (0..49, probe3(t) = t, a_t = 1+t):
    ;;   t + (1+t)*t + 10t = t^2 + 12t
    ;; acc = 40425 + 14700 = 55125; finals a = 51, v = 10 -> r = 55186.
    [d : i64 (deeprec (* v 1000))]
    ;; sum n=1..10000 of (a+b+c+n) = 5n - 2 -> 5*N(N+1)/2 - 2N = 250005000.
    (if (and (= r 55186) (= d 250005000))
      42
      1)))