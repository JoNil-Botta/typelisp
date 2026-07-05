(import stdlib.io)

;; FORCING TEST for M-B part 1: dead call-result store elision. `poke` returns
;; unit and is recursive on purpose (the opt2 leaf-inliner cannot delete the
;; call), so the loop keeps a REAL call whose result var is never read. The
;; old backend stored the dead result unconditionally (`movq %rax, -N(%rbp)`
;; every iteration); with the elision the loop body must contain NO %rax store
;; to a frame slot. The runtime check guards against over-elision (a live
;; store wrongly skipped would corrupt acc/i and change the sum -> exit 1);
;; target/dead-store-gate.sh additionally asserts the asm shape.
;; Recursive on purpose: a trivial leaf would be inlined at opt2, deleting the
;; call (and the dead result store with it).
(define (poke [x : i64]) : unit
  (if (<= x 0)
    unit
    (poke (- x 1))))

(define (spin [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          ;; unit call result: assigned to a fresh dead temp by the lowerer.
          (poke i)
          (set! acc (+ acc (* i 3)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (+ (io.arg-count) 3)]
    [r : i64 (spin n)]
    ;; n=4 (no args): acc = 3*(0+1+2+3) = 18.
    (if (= r 18)
      42
      1)))
