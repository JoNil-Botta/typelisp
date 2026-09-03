;; SUM-1. The per-cell address-taken precondition, on a program that takes ONE
;; global's address.
;;
;; P18's per-global cell mod-ref table used to require that NO global cell
;; address exists anywhere in the program: one `(&mut g)` withdrew the table
;; from every loop and from every other cell with it. The argument it rests on
;; is per cell, though -- `CompilerIrValue.GlobalAddr` names one global, and no
;; IR operation derives one cell's address from another's -- so the
;; address-taken cells now share one conservative bit and every other cell keeps
;; its own.
;;
;; Here `pc-open`'s address is handed to `pc-count!` and `pc-closed`'s is not.
;; Both are written at run time, so neither is a substitutable constant. The
;; fold loop reads `pc-closed` on every trip with a loop-bearing call between
;; the reads; that callee writes no cell, so the read is loop-invariant in fact.
;; Before this packet the `(&mut pc-open)` below refused it -- the table was not
;; built at all; now only `pc-open` is refused and `pc-closed` is hoisted into
;; the preheader (pinned by the asm-shape gate).
;;
;; `bump` walks the loop one past the end of the vector. At 0 every read is in
;; range and the printed fold pins the result; at 1 the last read is exactly at
;; `length`, so the run must still abort at that read with the same located
;; message the base compiler produced.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (pc-zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define pc-closed : i64
  0)
(define pc-open : i64
  0)
(define pc-other : i64
  0)
(define pc-vec : i64vec.Vec
  (pc-zero-vec 1))

(define (pc-ref [index : i64]) : i64
  (array-ref (i64vec.slots (& pc-vec)) index))

(define (pc-set! [index : i64] [value : i64]) : unit
  (set! (array-ref (i64vec.slots-mut (&mut pc-vec)) index) value))

;; The one place a cell ADDRESS enters this program.
(define (pc-count! [slot : (&mut slot i64)]) : unit
  (set! (deref slot) (+ (deref slot) 1)))

;; A SELF-RECURSIVE leaf the inliner leaves alone, so the call really is inside
;; the fold loop. It writes ONE cell -- `pc-other` -- which is what makes the
;; per-global table the deciding fact: the loop-wide gate refuses every global
;; for a loop that calls this, while the per-global row names `pc-other` and
;; leaves `pc-closed` alone.
(define (pc-digits [value : i64] [count : i64]) : i64
  (if (<= value 0)
    (begin
      (set! pc-other (+ pc-other count))
      count)
    (pc-digits (/ value 10) (+ count 1))))

(define (pc-fill! [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (pc-set! index (+ (* index 7) 1))
        (set! index (+ index 1))))))

(define (pc-fold [count : i64] [bump : i64]) : i64
  (let
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index (+ count bump))
        (begin
          (set!
            acc
            (+
              (* acc 31)
              (+ (* pc-closed (pc-ref index)) (pc-digits (pc-ref index) 0))))
          (set! index (+ index 1))))
      acc)))

(define (main) : i64
  (let
    [count : i64 (string.>int (io.arg 1))]
    [bump : i64 (string.>int (io.arg 2))]
    (begin
      (set! pc-vec (pc-zero-vec count))
      (set! pc-closed (+ count 1))
      (pc-fill! count)
      (pc-count! (&mut pc-open))
      (io.print-format "{}\n" (pc-fold count bump))
      (io.print-format "{}\n" pc-open)
      (io.print-format "{}\n" pc-other)
      42)))