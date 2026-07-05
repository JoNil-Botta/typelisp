(import stdlib.io)

;; FORCING TEST for M-G2a: args of gp-parallel DIRECT TAIL CALLS become
;; register-eligible. spin-a/spin-b are MUTUALLY tail-recursive (self tail
;; recursion is rewritten to a loop by opt-tailrec, so a self-call would never
;; reach the backend's IrInstrTailCall path). spin-a calls the recursive
;; `probe` before its tail call, so a/b/n are live ACROSS a real call and get
;; callee-saved homes -- the tail marshalling must read those CSR sources
;; BEFORE the epilogue restores them (`movq %rCSR, %argreg` ... restores ...
;; leave/jmp). Under the old contract every tail-call arg var was ineligible
;; (memory-sourced), so the marshalling reloaded each from -N(%rbp);
;; target/tail-arg-gate.sh asserts that shape is gone.
;;
;; whirl-a/whirl-b are the runtime-correctness stress: 6 args (the SysV
;; gp-parallel arity boundary), rotating across each hop so every marshalling
;; mistake (wrong order, source clobbered by the CSR restore, cycle mishandled)
;; corrupts the result; 5 call-spanning CSR candidates + 1 spill exercise
;; mixed register/frame sources. Depth 2,000,010 overflows the stack unless
;; the tail jmp path is intact (TCO regression also fails the 42 check).
;; Recursive on purpose so the leaf inliner cannot delete it: probe(x) = x.
(define (probe [x : i64]) : i64
  (if (<= x 0)
    0
    (+ 1 (probe (- x 1)))))

;; Swap a/b each hop; c accumulates probe(7)=7 on a-hops and 3 on b-hops.
(define (spin-a [a : i64] [b : i64] [c : i64] [n : i64]) : i64
  (if (<= n 0)
    (+ (* 2 a) (+ b c))
    (spin-b b a (+ c (probe 7)) (- n 1))))

(define (spin-b [a : i64] [b : i64] [c : i64] [n : i64]) : i64
  (if (<= n 0)
    (+ (* 2 a) (+ b c))
    (spin-a b a (+ c 3) (- n 1))))

;; Rotate (a,b,c,d,e) left each hop; the wrapped element gains probe(3)=3 on
;; a-hops and 1 on b-hops. Over any 10 hops each element wraps exactly twice
;; (once per phase) -> +4 per element per 10 hops.
(define (whirl-a [a : i64] [b : i64] [c : i64] [d : i64] [e : i64] [n : i64]) : i64
  (if (<= n 0)
    (+ a (+ (* 2 b) (+ (* 3 c) (+ (* 4 d) (* 5 e)))))
    (whirl-b b c d e (+ a (probe 3)) (- n 1))))

(define (whirl-b [a : i64] [b : i64] [c : i64] [d : i64] [e : i64] [n : i64]) : i64
  (if (<= n 0)
    (+ a (+ (* 2 b) (+ (* 3 c) (+ (* 4 d) (* 5 e)))))
    (whirl-a b c d e (+ a 1) (- n 1))))

(define (main) : i64
  (let
    ;; arg-count = 1 when run without args (program name); keeps the depths
    ;; even/10-divisible so the closed forms below hold.
    [n1 : i64 (* 2 (+ 500000 (io.arg-count)))]
    [n2 : i64 (* 10 (+ 200000 (io.arg-count)))]
    [r1 : i64 (spin-a 3 1 0 n1)]
    [r2 : i64 (whirl-a 1 2 3 4 5 n2)]
    ;; r1: n1=1000002 hops swap a/b back to (3,1); c = 10 per hop-pair
    ;;     = 5*n1 = 5000010; terminal hop is spin-a -> 2*3 + 1 + 5000010.
    ;; r2: n2=2000010 hops; each element += 4*(n2/10) = 800004; weights sum 15
    ;;     -> 55 + 15*800004 = 12000115.
    (if (= r1 5000017)
      (if (= r2 12000115)
        42
        2)
      1)))