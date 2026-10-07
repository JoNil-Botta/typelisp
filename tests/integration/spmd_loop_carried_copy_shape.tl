;; A SIMD foreach between two scalar `while` loops that re-assign the same
;; counter (#8394). Below opt2 the counter and the slice accessors have several
;; Mov definitions joined by back edges; the backend's copy-shape query must
;; still finish promptly (it used to explore those chains exponentially). The
;; lane-offset gather result is checked against a scalar recomputation.
(import stdlib.vector)
(import (vector.vector i64) as i64v)
(import spmd_vec_support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)

(define (check
  [values : (& values i64v.Vec)]
  [offsets : (& offsets i64v.Vec)]
  [out : (&mut out i64v.Vec)]
  [n : i64]) : bool
  (let
    [values-view (i64v.slots values)]
    [offsets-view (i64v.slots offsets)]
    [out-view (i64v.slots-mut out)]
    [k : i64 0]
    [ok : bool true]
    (while (< k 20)
      (if (< (array-ref values-view k) 0)
        (set! ok false)
        unit)
      (set! k (+ k 1)))
    (foreach
      ([i
          : i64
          0
          (if (> n 18)
            18
            n)])
      (set!
        (array-ref out-view i)
        (array-ref values-view (+ i (array-ref offsets-view (program-index))))))
    (set! k 0)
    (while (< k n)
      (if (and
        (< k 18)
        (not (= (array-ref out-view k) (array-ref values-view (+ k 2)))))
        (set! ok false)
        unit)
      (set! k (+ k 1)))
    ok))

(define (main) : i64
  (let
    [values : i64v.Vec (i64z.make 20)]
    [offsets : i64v.Vec (i64z.make 16)]
    [out : i64v.Vec (i64z.make 20)]
    [k : i64 0]
    (while (< k 20)
      (i64v.set-ref! (&mut values) k (+ 100 (* k 3)))
      (if (< k 16)
        (i64v.set-ref! (&mut offsets) k 2)
        unit)
      (set! k (+ k 1)))
    (if (and
      (check (& values) (& offsets) (&mut out) 9)
      (check (& values) (& offsets) (&mut out) 20))
      42
      1)))