(import "stdlib/io.tl")

;; FORCING TEST for M-G2b (per-call-region split via the widened caller-saved
;; call-spanning rescue). The churn loop keeps SIX values live across the
;; probe() call each iteration: acc, i, a, b, c (hot: >= 4 refs/iteration) and
;; v (exactly 3 uses, all clustered in the call-free stretch AFTER the call).
;; With only 5 callee-saved GP registers the coldest value -- v -- loses the
;; CSR competition and spills. Pre-M-G2b every one of v's three uses is a
;; frame access per iteration (the old rescue rejected v: it is live across
;; the block boundary of the loop, and %r9 is not free over its whole hull);
;; the loop-split rescue also cannot serve it (the loop body contains a call,
;; so only the saturated CSRs are offered). Post-M-G2b the rescue homes v in
;; a caller-saved register (%r8/%r9/%rsi/%rdi) over the call-free region: ONE
;; entry reload + three register uses per iteration.
;;
;; v is the only multiplied value, so every `imul` in churn involves v --
;; target/callregion-gate.sh asserts no imul reads a frame slot and that the
;; region register shape is present (FAILS pre-M-G2b: proven forcing).

;; Recursive on purpose so the leaf inliner cannot delete the call: probe(x) = x.
(define (probe [x : i64]) : i64
  (if (<= x 0) 0 (+ 1 (probe (- x 1)))))

;; NON-TAIL self-recursion (never taken at rounds = 1) keeps churn out of the
;; inliner AND out of opt-tailrec, so the gate can assert on the named
;; function's loop body.
(define (churn [v : i64] [rounds : i64]) : i64
  (let
    [a : i64 1] [b : i64 2] [c : i64 3]
    [acc : i64 0] [i : i64 0]
    (begin
      (while (< i 100)
        (begin
          (set! acc (+ acc (probe i)))     ; the call every value spans
          (set! acc (+ acc (+ a i)))       ; a,b,c stay hot (4-5 refs each)
          (set! acc (+ acc (* 2 a)))
          (set! a (+ a 1))
          (set! acc (+ acc (+ b i)))
          (set! acc (+ acc (* 2 b)))
          (set! b (+ b 1))
          (set! acc (+ acc (+ c i)))
          (set! acc (+ acc (* 2 c)))
          (set! c (+ c 1))
          (set! acc (+ acc (* v i)))       ; v's call-free 3-use region
          (set! acc (+ acc (* v a)))
          (set! acc (+ acc (* v b)))
          (set! i (+ i 1))))
      (let
        [r : i64 (+ acc (+ a (+ b (+ c v))))]
        (if (> rounds 1) (+ r (churn v (- rounds 1))) r)))))

(define (main) : i64
  (let
    ;; v = 10 when run without args (arg-count = 1); (arg-count) blocks
    ;; constant folding of the whole loop.
    [v : i64 (+ 9 (arg-count))]
    [r : i64 (churn v 1)]
    ;; per iteration t (0..99, a_t = 1+t, b_t = 2+t, c_t = 3+t, probe(t) = t):
    ;;   t + (1+2t) + (2+2t) + (2+2t) + (4+2t) + (3+2t) + (6+2t)
    ;;     + 10t + 10(2+t) + 10(4+2t)
    ;; acc = 219650; finals a=101 b=102 c=103 v=10 -> r = 219966.
    (if (= r 219966) 42 1)))
