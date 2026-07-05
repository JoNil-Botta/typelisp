(import stdlib.io)
(import stdlib.array)

;; FORCING TEST for GAP7: a pool value homed in %rbp (the 6th CSR) that is used
;; as a MEMORY BASE.
;;
;; churn6 mirrors rbp_sixth_csr, but the 6th call-spanning value is an ARRAY
;; HANDLE `v` that is INDEXED every iteration. Under the 6-CSR FPO pool the
;; handle lands in %rbp, and each `array-ref v ...` reads the descriptor
;; (data/len fat slots) through the handle as an addressing base -- i.e. off a
;; %rbp base. Before GAP7 the backend could not spell `off(%rbp)` for a POOL
;; base (the FPO rsp-rebase pass identifies frame refs textually by `(%rbp`), so
;; it STAGED the base through a scavenged scratch every access:
;;     movq %rbp, %r10
;;     movq 8(%r10), ...        ; len / data descriptor load
;; After GAP7 the %rbp base is spelled directly as the SIB scale-1 index form
;;     movq 8(,%rbp,1), ...
;; which is textually distinct from a frame reference `8(%rbp)` (so the rebase
;; pass and the peephole slot recognizers leave it alone) and semantically
;; identical -- no staging copy.
;;
;; The runtime check guards reconstruction (a clobbered/miscomputed base gives a
;; wrong sum or an OOB abort -> not 42); target/rbp-base-gate.sh additionally
;; asserts the asm SHAPE (a %rbp SIB base present, and NO `movq %rbp, %rSCRATCH`
;; staging of the descriptor base in the loop). FAILS pre-GAP7 (staged) -- proven
;; forcing.
;; Recursive so the leaf inliner cannot delete the call: probe6(x) = x.
(define (probe6 [x : i64]) : i64
  (if (<= x 0)
    0
    (+ 1 (probe6 (- x 1)))))

;; NON-TAIL self-recursion (never taken at rounds = 1) keeps churn6 out of the
;; inliner AND out of opt-tailrec, so the gate can assert on the named
;; function's loop body. The loop carries a real call (probe6), blocking
;; memory-LICM (the descriptor loads stay in the loop) and forcing the
;; call-spanning values -- including the array handle v -- into callee-saved
;; homes. Five hot i64 values (a,b,c,acc,i) fill r12..rbx; v is the 6th = %rbp.
(define (churn6 [v : (Array i64)] [rounds : i64]) : i64
  (let
    [a : i64 1]
    [b : i64 2]
    [c : i64 3]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i 5)
        (begin
          (set! acc (+ acc (probe6 i)))
          ; the call every value spans
          (set! acc (+ acc (+ a i)))
          ; a,b,c stay hot (>=4 refs each)
          (set! acc (+ acc (* 2 a)))
          (set! a (+ a 1))
          (set! acc (+ acc (+ b i)))
          (set! acc (+ acc (* 2 b)))
          (set! b (+ b 1))
          (set! acc (+ acc (+ c i)))
          (set! acc (+ acc (* 2 c)))
          (set! c (+ c 1))
          ;; v: the array handle base, dereferenced twice per iteration
          (set! acc (+ acc (array.ref v i)))
          (set! acc (+ acc (array.ref v (+ i 1))))
          (set! i (+ i 1))))
      (let
        [r : i64 (+ acc (+ a (+ b (+ c (array.ref v 0)))))]
        (if (> rounds 1)
          (+ r (churn6 v (- rounds 1)))
          r)))))

(define (main) : i64
  (let
    [n : i64 (+ (io.arg-count) 7)]
    ; n = 8 (no args)
    [v : (Array i64) (array.make-array i64 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! v i (* i 3))
          ; v[i] = 3i
          (set! i (+ i 1))))
      (let
        [r : i64 (churn6 v 1)]
        ;; per iteration t (0..4): a_t=1+t b_t=2+t c_t=3+t probe6(t)=t
        ;;   acc_t = t + (1+2t) + (2+2t) + (2+2t) + (4+2t) + (3+2t) + (6+2t)
        ;;         + v[t] + v[t+1]
        ;;         = 18 + 13t + 3t + 3(t+1) = 21 + 19t
        ;;   sum_{t=0..4}(21+19t) = 105 + 19*10 = 105 + 190 = 295
        ;; finals: a=6 b=7 c=8 v[0]=0 -> r = 295 + (6+7+8+0) = 316
        (if (= r 316)
          42
          1)))))
