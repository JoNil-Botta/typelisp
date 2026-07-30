(import stdlib.array)

;; FORCING TEST for GAP6a: fold a register-homed comparand into the fused
;; gep+load+compare+branch instead of staging it through a scratch register.
;;
;; `(array.length xs)` reads the descriptor length field at a CONSTANT
;; offset (fat-pointer offset 8). When it is single-use and feeds a branch
;; condition, the backend fuses gep+load+compare+branch: the length word is read
;; from memory and compared against `threshold` (a NON-immediate, register-homed
;; param), feeding the if-branch. Before GAP6a the register operand was staged
;; through a scratch:
;;     movq %rTHRESH, %r8
;;     cmpq %r8, 8(%rXS)
;; After GAP6a the home register is the compare operand directly:
;;     cmpq %rTHRESH, 8(%rXS)
;;
;; The never-taken self-recursion blocks the opt2 inliner so `check` keeps its
;; own frame (and threshold stays a register-homed param). A wrong/clobbered
;; operand yields a wrong branch -> not 42; target/cmp-fold-gate.sh asserts the
;; asm shape (FAILS pre-GAP6a: a staging movq feeds the fused compare).
(define (check [xs : (__tl_dyn-array i64)] [threshold : i64] [poke : i64]) : i64
  (if (< poke 0)
    (check xs threshold (+ poke 1))
    (if (< (array.length xs) threshold)
      1
      0)))

(define (main) : i64
  (let
    [xs : (__tl_dyn-array i64) (array.make-array i64 6)]
    (if (= (check xs 10 0) 1)
      (if (= (check xs 3 0) 0)
        42
        1)
      1)))