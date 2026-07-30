(import stdlib.io)

;; FORCING TEST for M-A (RC1): parameters become ordinary greedy candidates with
;; CALLEE-SAVED-only homes. `param-loop` has a REAL call in the loop (recursive
;; `bump`, so the leaf-inliner cannot delete it) plus two params -- a scalar
;; `n` and a handle `xs : (Array i64)` -- read EVERY iteration. Under the old
;; contract any clobber point stack-homed ALL params, so both were reloaded from
;; `-N(%rbp)` each iteration; under the new contract both must be copied ONCE at
;; entry into callee-saved registers (movq %rdi/%rsi, %r12..%r15/%rbx) and the
;; loop body must contain NO stack reload of either param. The runtime check
;; guards reconstruction (wrong home / clobbered CSR -> wrong sum -> exit 1);
;; target/param-csr-gate.sh additionally asserts the asm shape.
;; Recursive on purpose: a trivial leaf would be inlined at opt2, deleting the
;; call and the clobber point with it. bump(i) = i+1 for i >= 0.
(define (bump [x : i64]) : i64
  (if (<= x 0)
    1
    (+ 1 (bump (- x 1)))))

(define (param-loop [xs : (__tl_dyn-array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          ;; handle param used every iteration (array-ref keeps xs live)
          (set! acc (+ acc (array-ref xs i)))
          ;; real user call: clobbers every caller-saved register
          (set! acc (+ acc (bump i)))
          ;; scalar param used every iteration AFTER the call
          (set! acc (+ acc n))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (+ (io.arg-count) 3)]
    [xs : (__tl_dyn-array i64) (make-array i64 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (* i 3))
          (set! i (+ i 1))))
      (let
        [r : i64 (param-loop xs n)]
        ;; n=4 (no args): array sum = 3*(0+1+2+3) = 18; bump(i) sums 1+2+3+4 =
        ;; 10; n added per iteration = 16. total = 44.
        (if (= r 44)
          42
          1)))))