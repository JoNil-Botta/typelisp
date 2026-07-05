(import stdlib.io)
(import stdlib.array)

;; FORCING TEST for M-C2 (part 3): direct register-homed gep-load base.
;;
;; `probe` is a bounds-checked array-sum whose loop carries a real CALL
;; (`bump`), so (a) memory-LICM cannot hoist the descriptor loads out of the
;; loop (call invalidation) and (b) the array param `xs` gets a CALLEE-SAVED
;; register home (M-A/M-A2). Every iteration therefore re-reads the
;; descriptor's len (fat offset 8) and data pointer (fat offset 0) through the
;; fused gep+load path with a REGISTER-HOMED base. Before M-C2 the backend
;; staged that base through a scavenged scratch every time:
;;     movq %rCSR, %r10
;;     movq 8(%r10), ...
;; After M-C2 the home register is the addressing base directly:
;;     movq 8(%rCSR), ...
;; and `probe` contains NO reg-reg copy OF the array's home register at all.
;;
;; The runtime check guards reconstruction (a wrong base or clobbered home
;; produces a wrong sum or an OOB abort -> not 42); target/gep-direct-gate.sh
;; additionally asserts the asm shape.
;; Self-recursive so the opt2 inliner cannot inline it: the loop keeps a real
;; call, which blocks LICM (descriptor loads stay in the loop) and forces the
;; call-spanning loop values into callee-saved homes.
(define (bump [x : i64]) : i64
  (if (> x 100000)
    (bump (- x 100000))
    (+ x 1)))

(define (probe [xs : (Array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (bump (+ acc (array.ref xs i))))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (+ (io.arg-count) 5)]
    [xs : (Array i64) (array.make-array i64 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (* i 2))
          (set! i (+ i 1))))
      (let
        [r : i64 (probe xs n)]
        ;; n = 6 (no args): r = sum(2*i, i<6) + 6 = 30 + 6 = 36.
        (if (= r 36)
          42
          1)))))