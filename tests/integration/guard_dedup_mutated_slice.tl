;; IT-2's negative: the same two-loop scan, but the container is REBOUND
;; between the two loops -- a helper replaces the module global with a shorter
;; vector, which rewrites the descriptor words the two guards read. The
;; descriptor the first loop's guard loaded is therefore stale by the time the
;; second guard runs, so IT-2's bypass-edge PRE must refuse to let the second
;; guard reuse it: the rebinding helper's whole-program summary says it writes,
;; and the region between the two guards contains that call.
;;
;; Both guards must stay, and the program must behave identically at every
;; optimization level: with `cut` zero the scan runs to completion over the
;; full container, and with `cut` shorter than the span the second loop walks
;; off the end of the NEW buffer and the bounds check has to abort. A reused
;; stale length would read past the shortened allocation instead.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector u8) as u8vec)

(define gd-buf : u8vec.Vec
  (u8vec.Vec (__tl_make-array u8 1) 1))

(define (gd-fill [n : i64]) : unit
  (let
    [fresh : u8vec.Vec (u8vec.Vec (__tl_make-array u8 n) n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set!
            (array-ref (u8vec.slots-mut (&mut fresh)) i)
            (cast (+ i 1) : u8))
          (set! i (+ i 1))))
      (set! gd-buf fresh))))

;; The write between the loops: a shorter buffer under the same name.
(define (gd-cut [n : i64]) : unit
  (gd-fill n))

(define (gd-scan [start : i64] [len : i64] [cut : i64]) : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    [words : i64 (- len 7)]
    (begin
      (while (< i words)
        (begin
          (set!
            acc
            (+
              (* acc 31)
              (cast (array-ref (u8vec.slots (& gd-buf)) (+ start i)) : i64)))
          (set! i (+ i 8))))
      (if (> cut 0)
        (gd-cut cut)
        unit)
      (while (< i len)
        (begin
          (set!
            acc
            (+
              (* acc 256)
              (cast (array-ref (u8vec.slots (& gd-buf)) (+ start i)) : i64)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [cut : i64 (string.>int (io.arg 2))]
    (begin
      (gd-fill n)
      (io.print-format "{}\n" (gd-scan 0 n cut))
      42)))