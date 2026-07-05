(import stdlib.array)

;; FORCING TEST for SCAV2 (backend descriptor-CSE of repeated global-handle
;; loads via the owner-map peephole).
;;
;; A module-level global `(Array i64)` holds a handle (a pointer to the array
;; descriptor). Every access re-materialises the handle with `movq SYM(%rip),%rX`
;; -- there is no single-instruction RIP fold for the double indirection. A
;; bounds-checked read loads the handle TWICE within one access (once to read the
;; length at +8, once to read the data pointer at +0), separated by the bounds
;; check `cmp; jb ok; call tl_oob_abort; ok:`. Before SCAV2 the second load is a
;; fresh `movq SYM(%rip),%rY` because the owner map was cleared by the noreturn
;; abort + the guard-ok label; SCAV2 (a) tracks SYM(%rip) globals in the owner
;; map and (b) carries that map across the abort + guard-ok label, so the second
;; load reuses the register already holding the handle (drop, or reg-reg move).
;;
;; `probe` reads gtab[i] under a never-taken self-recursion that blocks the leaf
;; inliner + TCO so the named body survives for the gate to inspect
;; (target/global-handle-gate.sh; FAILS pre-SCAV2 which emits two handle loads).
(define gtab : (Array i64)
  (array.make-array i64 16))

(define (probe [i : i64]) : i64
  (if (< i -999999)
    (probe (- i 1))
    (array.ref gtab i)))

(define (main) : i64
  (begin
    (array-set! gtab 3 42)
    (let
      [r : i64 (probe 3)]
      (if (= r 42)
        42
        1))))
