;; FORCING TEST for M6-I (memory-operand compare for a scalar global read).
;;
;; A scalar global read is `movq g(%rip), %rN` on both targets. When it feeds a
;; compare, x86 can read the cell through the compare's own memory operand
;; instead, and the materialising `movq` disappears:
;;
;;     movq g(%rip), %r8 ; cmpq %r8, %rax ; jne   ->   cmpq g(%rip), %rax ; jne
;;
;; `probe-rhs` puts the read on the compare's RIGHT (the AT&T SOURCE slot) and
;; `probe-lhs` on its LEFT (the DESTINATION slot); both must fold, and both
;; must keep the branch sense they had. `probe-refused` binds the read to a
;; local it reads TWICE, so the value has to survive in a register and the
;; `movq` must still be there -- the nearest neighbour that proves the fold is
;; gated on single use rather than on the operand being a global at all.
;;
;; Each probe hides behind a never-taken self-recursion, which blocks the opt2
;; leaf inliner so the named body survives for the gate to read. The globals
;; are seeded through `gcmp-opaque`, whose own self-recursion keeps its result
;; out of reach of constant propagation, so the compares stay real compares.
;;
;; The gate is check_global_cmp_mem_fold in scripts/verify-asm-shape-gates.sh;
;; it FAILS on the pre-M6-I compiler, which stages every global read through a
;; scratch register first.

(define gcmp-gen : i64
  0)

(define gcmp-limit : i64
  0)

(define (gcmp-opaque [n : i64] [poke : i64]) : i64
  (if (< poke 0)
    (gcmp-opaque n (+ poke 1))
    (+ n 7)))

;; The global is the compare's LEFT operand: `cmpq %rX, gcmp_gen(%rip)`.
(define (probe-lhs [x : i64] [poke : i64]) : i64
  (if (< poke 0)
    (probe-lhs x (+ poke 1))
    (if (= gcmp-gen x)
      1
      0)))

;; The global is the compare's RIGHT operand: `cmpq gcmp_limit(%rip), %rX`.
;; An ORDERED compare, so the operand order is load-bearing: a swapped fold
;; would invert the branch and change the answer.
(define (probe-rhs [x : i64] [poke : i64]) : i64
  (if (< poke 0)
    (probe-rhs x (+ poke 1))
    (if (< x gcmp-limit)
      1
      0)))

;; Refused: the read is bound to a local that is read twice, so retiring it
;; would drop the definition the second read needs.
(define (probe-refused [x : i64] [poke : i64]) : i64
  (if (< poke 0)
    (probe-refused x (+ poke 1))
    (let
      [gen : i64 gcmp-gen]
      (if (= gen x)
        (+ gen 1)
        0))))

(define (main) : i64
  (begin
    (set! gcmp-gen (gcmp-opaque 0 0))
    (set! gcmp-limit (gcmp-opaque 993 0))
    (if (not (= (probe-lhs 7 0) 1))
      1
      (if (not (= (probe-lhs 8 0) 0))
        2
        (if (not (= (probe-rhs 999 0) 1))
          3
          (if (not (= (probe-rhs 1000 0) 0))
            4
            (if (not (= (probe-rhs 1001 0) 0))
              5
              (if (not (= (probe-refused 7 0) 8))
                6
                (if (not (= (probe-refused 9 0) 0))
                  7
                  42)))))))))
