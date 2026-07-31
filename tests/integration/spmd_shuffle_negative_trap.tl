; Active selectors are signed i64 values. A negative selector in the second
; logical destination lane must take the standard bounds-abort path.
(import stdlib.vector)
(import (vector.vector i64) as i64v)
(import spmd_vec_support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)

(define (main) : i64
  (let
    [n : i64 2]
    [xs : i64v.Vec (i64z.make n)]
    [selectors : i64v.Vec (i64z.make n)]
    [out : i64v.Vec (i64z.make n)]
    (begin
      (i64v.set (&mut xs) 0 11)
      (i64v.set (&mut xs) 1 22)
      (i64v.set (&mut selectors) 0 0)
      (i64v.set (&mut selectors) 1 -1)
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
      0)))