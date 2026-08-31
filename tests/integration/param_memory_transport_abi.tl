(import stdlib.io)

;; FLT-1 wrong-code REGRESSION fixture.
;;
;; A by-value `(Array i64 3)` is 24 bytes, so lowering gives it the internal
;; by-memory ABI transport type `__tl_internal_abi_mem_s24__...`. The backend
;; passes such a parameter entirely in the incoming STACK area and advances
;; NEITHER argument bank (the private-memory arm of
;; compiler-backend-emit-param-spills-from), but the register allocator's
;; parameter walk used to advance its integer ABI index anyway -- the transport
;; is a nominal Struct, so it passed the "integer parameter" test. Every
;; parameter after it was therefore pinned to the incoming register of its
;; SUCCESSOR, and the prologue's position-ordered entry copies destroyed each
;; source before the next copy read it:
;;
;;     movq %rdi, %rsi        ; a's home, from a's real incoming register
;;     movq %rsi, %rdx        ; b's home, from %rsi -- already overwritten
;;     movq %rdx, %rcx        ; c's home, from %rdx -- already overwritten
;;     leaq 8(%rsp), %rdi
;;
;; so a, b and c all arrived holding a's value. Only --opt-level 2 reached the
;; pin path; opt0/opt1 were correct, which is why no gate caught it.
;;
;; The optimizer refuses to inline a callee with a private-memory parameter
;; (opt-inline-params-have-private-memory?), so these boundaries survive opt2.
(define (mem-then-three [v : (Array i64 3)] [a : i64] [b : i64] [c : i64]) : i64
  (+ (array-ref v 0) (+ (* a 3) (+ (* b 5) (* c 7)))))

(define (mem-then-two [v : (Array i64 3)] [a : i64] [b : i64]) : i64
  (+ (array-ref v 2) (+ (* a 3) (* b 5))))

(define (main) : i64
  (let
    ;; arg-count is 1 with no arguments; deriving every value from it keeps the
    ;; calls out of reach of constant folding.
    [n : i64 (io.arg-count)]
    [v : (Array i64 3) (array (+ n 1) (+ n 2) (+ n 3))]
    ;; v = (2 3 4)
    ;; mem-then-three: 2 + (1*3 + 2*5 + 3*7) = 2 + 34 = 36
    ;; mem-then-two:   4 + (4*3 + 5*5)       = 4 + 37 = 41
    [r1 : i64 (mem-then-three v n (+ n 1) (+ n 2))]
    [r2 : i64 (mem-then-two v (+ n 3) (+ n 4))]
    (begin
      (io.println "{}" (+ r1 r2))
      ;; With the bug a == b == c: 2 + (3 + 5 + 7) = 17 and 4 + (12 + 20) = 36,
      ;; a total of 53 instead of 77.
      (if (= (+ r1 r2) 77)
        42
        1))))