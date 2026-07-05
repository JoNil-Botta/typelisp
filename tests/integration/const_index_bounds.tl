(import stdlib.io)
(import stdlib.array)

;; FORCING TEST for GAP6d: a constant array index folds into the bounds-check
;; compare instead of being materialised into a register.
;;
;; `(array.ref xs 2)` has a CONSTANT index (2) but a DYNAMIC length (xs is
;; a param of unknown size, so the check cannot be optimised away). Before GAP6d
;; the index was materialised and compared:
;;     movl $2, %rIDX
;;     cmpq %rLEN, %rIDX
;;     jb ok
;; After GAP6d the constant folds into the compare (K < len <=> len > K):
;;     cmpq $2, %rLEN
;;     ja ok
;;
;; The never-taken self-recursion blocks the opt2 inliner. Correctness: xs[2] is
;; set to 42 and read back; a wrong bound (mis-flipped jcc) would either falsely
;; abort or read out of bounds -> not 42. target/const-index-gate.sh asserts the
;; asm shape (FAILS pre-GAP6d: an `movl $2`/`movq $2` index materialisation).
(define (get2 [xs : (Array i64)] [poke : i64]) : i64
  (if (< poke 0)
    (get2 xs (+ poke 1))
    (array.ref xs 2)))

(define (main) : i64
  (let
    [xs : (Array i64) (array.make-array i64 5)]
    (begin
      (array-set! xs 2 42)
      (if (= (get2 xs 0) 42)
        42
        1))))