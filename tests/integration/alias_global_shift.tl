;; ALIAS-1. A descending shift loop over a MODULE-GLOBAL vector: the exact
;; shape benchmarks/regalloc_greedy's `rg-union-insert-segment!` runs, and the
;; one the packet's rule is about.
;;
;; The loop's only write is a scalar element store through the data pointer the
;; global's descriptor holds. Element storage is a different allocation from
;; the cell and from the descriptor's two header words, so the cell load, the
;; length and the data pointer are loop-invariant in fact; with the rule in
;; place LICM lifts all three into the preheader before `bce_version` runs, the
;; versioner then reads an invariant length and takes both bounds checks out of
;; the fast clone.
;;
;; `bump` shifts the cursor one past the end. At 0 every write is in range and
;; the printed fold pins the result; at 1 the first write is exactly at
;; `length`, so the run must still abort at that store with the same located
;; message the base compiler produced -- the versioning guard fails and the
;; original, still-checked loop runs.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (al-zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define al-entry-words : i64
  3)
(define al-vec : i64vec.Vec
  (al-zero-vec 1))

(define (al-ref [index : i64]) : i64
  (array-ref (i64vec.slots (& al-vec)) index))

(define (al-set! [index : i64] [value : i64]) : unit
  (set! (array-ref (i64vec.slots-mut (&mut al-vec)) index) value))

(define (al-fill! [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index (* count al-entry-words))
      (begin
        (al-set! index (+ (* index 7) 1))
        (set! index (+ index 1))))))

;; compiler-reg-live-union-insert-segment!'s shift: entries move up by one
;; whole entry, walked downward so the copy never overwrites a source it has
;; not read yet.
(define (al-shift! [floor : i64] [count : i64] [bump : i64]) : unit
  (let
    [cursor : i64 (+ (- (* count al-entry-words) 1) bump)]
    (while (>= cursor floor)
      (begin
        (al-set! (+ cursor al-entry-words) (al-ref cursor))
        (set! cursor (- cursor 1))))))

(define (al-fold [count : i64]) : i64
  (let
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index (* (+ count 1) al-entry-words))
        (begin
          (set! acc (+ (* acc 31) (al-ref index)))
          (set! index (+ index 1))))
      acc)))

(define (main) : i64
  (let
    [count : i64 (string.>int (io.arg 1))]
    [bump : i64 (string.>int (io.arg 2))]
    (begin
      (set! al-vec (al-zero-vec (* (+ count 1) al-entry-words)))
      (al-fill! count)
      (al-shift! 0 count bump)
      (io.print-format "{}\n" (al-fold count))
      42)))