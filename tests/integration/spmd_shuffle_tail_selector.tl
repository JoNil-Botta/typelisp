; A single partial SIMD gang with an exactly-sized varying-selector array.
; Inactive destination lanes must not read either input past element 2.
(import stdlib.vector)
(import (vector.vector i64) as i64v)
(import spmd_vec_support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)

(define (main) : i64
  (let
    [n : i64 3]
    [xs : i64v.Vec (i64z.make n)]
    [selectors : i64v.Vec (i64z.make n)]
    [out : i64v.Vec (i64z.make n)]
    (begin
      (i64v.set (&mut xs) 0 11)
      (i64v.set (&mut xs) 1 22)
      (i64v.set (&mut xs) 2 33)
      (i64v.set (&mut selectors) 0 0)
      (i64v.set (&mut selectors) 1 1)
      (i64v.set (&mut selectors) 2 2)
      (let
        [xs-slots (i64v.slots (& xs))]
        [selector-slots (i64v.slots (& selectors))]
        [out-slots (i64v.slots-mut (&mut out))]
        (foreach
          ([i : i64 0 n])
          (array-set!
            out-slots
            i
            (spmd-shuffle (array-ref xs-slots i) (array-ref selector-slots i)))))
      (if (and
        (= (i64v.get (& out) 0 0) 11)
        (= (i64v.get (& out) 1 0) 22)
        (= (i64v.get (& out) 2 0) 33))
        42
        1))))