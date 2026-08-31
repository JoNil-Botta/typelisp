;; I3-1 abort coverage: a sole-call helper that CARRIES the abort is absorbed
;; whole at opt2, and the abort it owns keeps its own site and message.
;;
;; `sca-probe` is acyclic, takes four parameters (below the arity floor) and is
;; padded past the cost model's block fuel, so the sole-call tier is the only
;; thing that can take it -- and at opt2 it does, which is what makes this the
;; interesting case: the failing bounds check that fires below is one the
;; merged `main` now owns, cloned with its own ok-label, and the location and
;; text it reports must still be the ones the CALLEE's source line carries.
;;
;; argv[1] is the vector length and argv[2] the index to read. The manifest row
;; passes an index one past the end, so the check fails and the process aborts.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (sca-zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define sca-data : i64vec.Vec
  (sca-zero-vec 1))

(define (sca-probe
  [values-vec : (& values i64vec.Vec)]
  [index : i64]
  [salt : i64]
  [rounds : i64]) : i64
  (let
    [values (i64vec.slots values-vec)]
    [bias : i64 salt]
    [scale : i64 1]
    (begin
      ;; Two padding ladders, eight forward arms each and no back edge
      ;; anywhere. Between them they carry this body past the cost model's
      ;; block fuel while leaving it ACYCLIC, which is exactly the pair of
      ;; properties the sole-call tier's clauses read: a loop-carrying body is
      ;; refused at any size, a loop-free one at a straight-line site is
      ;; admitted at any size. Guard arms rather than a nested if-ladder
      ;; because that is the form the lint gate asks for; the lowered shape,
      ;; and so the absorption verdict, is the same either way.
      (cond
        [(< salt 2) (set! bias 2)]
        [(< salt 4) (set! bias 4)]
        [(< salt 8) (set! bias 8)]
        [(< salt 16) (set! bias 16)]
        [(< salt 32) (set! bias 32)]
        [(< salt 64) (set! bias 64)]
        [(< salt 128) (set! bias 128)]
        [else (set! bias 256)])
      ;; The second ladder keys on a different parameter, so the merged body
      ;; keeps two independent forward webs rather than one long chain. The
      ;; manifest row pins the abort below to this file's line 64, so the two
      ;; ladders together must keep their original line count.
      (cond
        [(= rounds 0) (set! scale 1)]
        [(= rounds 1) (set! scale 3)]
        [(= rounds 2) (set! scale 5)]
        [(= rounds 3) (set! scale 7)]
        [(= rounds 4) (set! scale 11)]
        [(= rounds 5) (set! scale 13)]
        [(= rounds 6) (set! scale 17)]
        [else (set! scale 19)])
      (+ (* scale (array-ref values index)) bias))))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [probe : i64 (string.>int (io.arg 2))]
    [i : i64 0]
    (begin
      (set! sca-data (sca-zero-vec n))
      (while (< i n)
        (begin
          (set! (array-ref (i64vec.slots-mut (&mut sca-data)) i) (* i 3))
          (set! i (+ i 1))))
      (io.print-format "{}\n" (sca-probe (& sca-data) probe 5 2))
      42)))