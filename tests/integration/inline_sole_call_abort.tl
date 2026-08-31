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
      (if (< salt 2)
        (set! bias 2)
        (if (< salt 4)
          (set! bias 4)
          (if (< salt 8)
            (set! bias 8)
            (if (< salt 16)
              (set! bias 16)
              (if (< salt 32)
                (set! bias 32)
                (if (< salt 64)
                  (set! bias 64)
                  (if (< salt 128)
                    (set! bias 128)
                    (set! bias 256))))))))
      (if (= rounds 0)
        (set! scale 1)
        (if (= rounds 1)
          (set! scale 3)
          (if (= rounds 2)
            (set! scale 5)
            (if (= rounds 3)
              (set! scale 7)
              (if (= rounds 4)
                (set! scale 11)
                (if (= rounds 5)
                  (set! scale 13)
                  (if (= rounds 6)
                    (set! scale 17)
                    (set! scale 19))))))))
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