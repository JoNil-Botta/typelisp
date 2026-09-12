;; FORCING TEST for BE-6 (memory-operand arithmetic for a scalar global read)
;; and CANON-G (a commutative op's global-cell operand canonicalises to the
;; right).
;;
;; A scalar global read is `movq g(%rip), %rN` on both targets. When it is the
;; RIGHT operand of an integer add, x86 can read the cell through the add's own
;; memory operand instead, and the materialising `movq` disappears:
;;
;;     movq g(%rip), %r8 ; addq %r8, %rax   ->   addq g(%rip), %rax
;;
;; `probe-rhs` writes the read on the add's right. `probe-lhs` writes it on the
;; LEFT, where the fold has no form; CANON-G commutes the operands ahead of the
;; backend, so this body must fold exactly as the first. `probe-refused` binds
;; the read to a local it reads TWICE, so the value has to survive in a
;; register and the `movq` must still be there -- the nearest neighbour that
;; proves the fold is gated on the operand being a single read.
;;
;; Each probe hides behind a never-taken self-recursion, which blocks the opt2
;; leaf inliner so the named body survives for the gate to read. The globals
;; are seeded through `gadd-opaque`, whose own self-recursion keeps its result
;; out of reach of constant propagation, so the adds stay real adds.
;;
;; The gate is check_global_add_mem_fold in scripts/verify-asm-shape-gates.sh;
;; it FAILS on the pre-BE-6 compiler, which stages the global read through a
;; scratch register first, and on the pre-CANON-G compiler for `probe-lhs`.
(define gadd-k : i64
  0)
(define gadd-m : i64
  0)

(define (gadd-opaque [n : i64] [poke : i64]) : i64
  (if (< poke 0)
    (gadd-opaque n (+ poke 1))
    (+ n 7)))

;; The global is the add's RIGHT operand: `addq gadd_k(%rip), %rX`.
(define (probe-rhs [x : i64] [poke : i64]) : i64
  (if (< poke 0)
    (probe-rhs x (+ poke 1))
    (+ (* x 3) gadd-k)))

;; The global is the add's LEFT operand; CANON-G makes it the right one.
(define (probe-lhs [x : i64] [poke : i64]) : i64
  (if (< poke 0)
    (probe-lhs x (+ poke 1))
    (+ gadd-m (* x 3))))

;; Refused: the read is bound to a local that is read twice, so retiring it
;; would drop the definition the second read needs.
(define (probe-refused [x : i64] [poke : i64]) : i64
  (if (< poke 0)
    (probe-refused x (+ poke 1))
    (let
      [k : i64 gadd-k]
      (+ (+ x k) (* k 5)))))

(define (main) : i64
  (begin
    (set! gadd-k (gadd-opaque 3 0))
    (set! gadd-m (gadd-opaque 13 0))
    (cond
      [(not (= (probe-rhs 4 0) 22)) 1]
      [(not (= (probe-lhs 4 0) 32)) 2]
      [(not (= (probe-refused 4 0) 64)) 3]
      [else 42])))