;; VT-1. The strided scan whose index is STRENGTH-REDUCED: `at = base + 3*i`
;; becomes a second header phi stepping by three, and after that rewrite the
;; multi-block variable-base recovery -- which matched only a syntactic multiple
;; of the counter -- saw a Phi and derived nothing, so both checks stayed.
;; regalloc_greedy's `rg-union-refresh-max!` is the measured shape and this is
;; its skeleton: a two-arm body (so the loop is multi-block), a read at
;; `base + 3*i + 1` and a write at `base + 3*i + 2` against one invariant
;; length.
;;
;; With the derived-induction arm the two accesses are one derived family, the
;; guard states its extremal pair once, and the fast clone carries neither
;; check.
;;
;; `bump` walks the scan past the vector: at 0 every access is in range and the
;; printed fold pins the result; at 2 the read at `base + 3*i + 1` is past the
;; end, so the run must still abort there with the same located message the
;; base compiler produced.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (vd-zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define vd-entry-words : i64
  3)
(define vd-vec : i64vec.Vec
  (vd-zero-vec 1))

(define (vd-ref [index : i64]) : i64
  (array-ref (i64vec.slots (& vd-vec)) index))

(define (vd-set! [index : i64] [value : i64]) : unit
  (set! (array-ref (i64vec.slots-mut (&mut vd-vec)) index) value))

(define (vd-fill! [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index (* count vd-entry-words))
      (begin
        (vd-set! index (* index 5))
        (set! index (+ index 1))))))

;; compiler-reg-live-union-refresh-max!: a running maximum written back into
;; every entry's third word.
(define (vd-refresh! [base : i64] [count : i64]) : unit
  (let
    [index : i64 0]
    [running : i64 -1000000]
    (while (< index count)
      (let
        [at : i64 (+ base (* index vd-entry-words))]
        [end : i64 (vd-ref (+ at 1))]
        (begin
          (when (> end running) (set! running end))
          (vd-set! (+ at 2) running)
          (set! index (+ index 1)))))))

(define (vd-fold [count : i64]) : i64
  (let
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! acc (+ (* acc 31) (vd-ref index)))
          (set! index (+ index 1))))
      acc)))

(define (main) : i64
  (let
    [count : i64 (string.>int (io.arg 1))]
    [bump : i64 (string.>int (io.arg 2))]
    [len : i64 (+ (* count vd-entry-words) vd-entry-words)]
    (begin
      (set! vd-vec (vd-zero-vec len))
      (vd-fill! count)
      ;; `base` is READ back out of the vector (it is zero, but the compiler
      ;; cannot know that) so the index stays `base + 3*i + k` with a runtime
      ;; base: a literal base folds to `3*i`, which the ordinary literal-scale
      ;; recovery already reads.
      (vd-refresh! (vd-ref 0) (+ count bump))
      (io.print-format "{}\n" (vd-fold len))
      42)))