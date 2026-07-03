(import "stdlib/io.tl")

;; FORCING TEST for GAP2b: register-PAIR homing for 16-byte group values.
;;
;; `mk` returns a 16-byte enum (MaybeI64 shape: tag word + i64 payload), so its
;; call result in `probe` is a register-group var. The never-taken
;; self-recursion blocks inlining, keeping a real call in probe's loop. The
;; scrutinee is matched directly (no Mov, no phi), so it is a GAP2b v1 pair
;; candidate; probe's other loop values leave at least two callee-saved
;; registers free over its short interval. Before GAP2b every iteration
;; round-tripped the result through the group's two frame slots:
;;     movq %rax, -N(%rsp)
;;     movq %rdx, -M(%rsp)
;;     cmpq $k, -N(%rsp)
;;     movq -M(%rsp), ...
;; After GAP2b the value lives in a callee-saved register pair:
;;     movq %rax, %rCSR0
;;     movq %rdx, %rCSR1
;;     cmpq $k, %rCSR0        ;; tag read straight from the pair
;; and the payload word is read from %rCSR1 with no frame traffic.
;; The runtime loop checksums tag+payload over mixed Some/None values (a wrong
;; word order, clobbered pair half, or stale slot read produces a wrong sum ->
;; not 42); target/group-pair-gate.sh additionally asserts the asm shape.
(defenum MaybeVal
  (MNone)
  (MSome i64))

(define (mk [i : i64] [flag : i64]) : MaybeVal
  (if (> flag 1000000)
    (mk i (- flag 1000000))
    (if (= (% i 3) 0)
      (MNone)
      (MSome (+ (* i 5) 1)))))

(define (probe [n : i64]) : i64
  (if (> n 1000000)
    (probe (- n 1000000))
    (let
      [i : i64 0]
      [acc : i64 0]
      (begin
        (while (< i n)
          (begin
            (match (mk i i)
              [(MSome v) (set! acc (+ acc v))]
              [(MNone) (set! acc (+ acc 1))])
            (set! i (+ i 1))))
        acc))))

(define (main) : i64
  (let
    [n : i64 (+ (arg-count) 8)]
    [r : i64 (probe n)]
    ;; n = 9 (no args): i in 0..8; i%3==0 -> +1 (i=0,3,6 -> 3);
    ;; others: 5i+1 for i in {1,2,4,5,7,8} = 6+11+21+26+36+41 = 141.
    ;; total = 144.
    (if (= r 144)
      42
      1)))