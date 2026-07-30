(import stdlib.io)

;; FORCING TEST for M-A2: HANDLE args of direct calls become register-eligible.
;; `sum-args` passes its private dynamic-array handle param `xs` as an argument
;; to a direct call (`probe`, recursive so the leaf-inliner cannot delete it) inside
;; a loop, and also reads it directly every iteration. Under the old contract
;; the gp-parallel handle-arg rule kept xs memory-sourced (ineligible), so it
;; was reloaded from `-N(%rbp)` each iteration; under the new contract xs is an
;; ordinary greedy candidate, copied ONCE at entry into a callee-saved register
;; (movq %rdi, %r12..%r15/%rbx) with a frame-free loop body. The runtime check
;; guards reconstruction (wrong home / clobbered CSR -> wrong sum -> exit 1);
;; target/handle-arg-gate.sh additionally asserts the asm shape.
;; Recursive on purpose: a trivial leaf would be inlined at opt2, deleting the
;; call (and the handle arg) with it. probe(xs, i) = i + xs[0].
(define (probe [xs : (__tl_dyn-array i64)] [i : i64]) : i64
  (if (<= i 0)
    (array-ref xs 0)
    (+ 1 (probe xs (- i 1)))))

(define (sum-args [xs : (__tl_dyn-array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          ;; handle passed as a DIRECT CALL ARG every iteration
          (set! acc (+ acc (probe xs i)))
          ;; and used directly too (keeps xs hot in the loop)
          (set! acc (+ acc (array-ref xs i)))
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
        [r : i64 (sum-args xs n)]
        ;; n=4 (no args): xs[0]=0 so probe(xs,i)=i; xs[i]=3i; acc adds 4i per
        ;; iteration -> 4*(0+1+2+3) = 24.
        (if (= r 24)
          42
          1)))))