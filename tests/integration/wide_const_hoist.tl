(import stdlib.io)

;; FORCING TEST for loop-hoisted wide BinOp RHS literals. The repeated
;; 2654435761 operands do not fit x86-64's signed imm32 encoding, but both
;; sites share one loop-scoped register in the eligible leaf loop.
(define (wide-leaf [n : i64] [rounds : i64]) : i64
  (let
    [acc : i64 1]
    (begin
      (while (> n 0)
        (begin
          (set! acc (bit-xor (* acc 2654435761) 2654435761))
          (set! n (/ n 2))))
      ;; Non-tail self-recursion keeps the named function out of the inliner.
      (if (> rounds 1)
        (+ acc (wide-leaf n (- rounds 1)))
        acc))))

(define (opaque [value : i64] [rounds : i64]) : i64
  (if (> rounds 1)
    (+ value (opaque value (- rounds 1)))
    value))

;; The call makes this loop ineligible, so both wide literals retain the
;; ordinary per-site materialisation fallback.
(define (wide-call [n : i64] [rounds : i64]) : i64
  (let
    [original : i64 n]
    [acc : i64 1]
    (begin
      (while (> n 0)
        (begin
          (set! acc (bit-xor (* acc 2654435761) 2654435761))
          (set! acc (opaque acc 1))
          (set! n (/ n 2))))
      (if (> rounds 1)
        (+ acc (wide-call original (- rounds 1)))
        acc))))

(define (main) : i64
  (let
    [n : i64 (+ 32 (io.arg-count))]
    [leaf : i64 (wide-leaf n 1)]
    [called : i64 (wide-call n 1)]
    (if (= leaf -8834157407922256111)
      (if (= called leaf)
        42
        2)
      1)))