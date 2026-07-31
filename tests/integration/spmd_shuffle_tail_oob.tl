; In a three-lane tail gang, selector 3 names an inactive source lane and must
; trap. The uniform source makes sure validation cannot be optimized away.
(import stdlib.vector)
(import (vector.vector i64) as i64v)
(import spmd_vec_support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)

(define (main) : i64
  (let
    [n : i64 3]
    [selectors : i64v.Vec (i64z.make n)]
    [out : i64v.Vec (i64z.make n)]
    (begin
      (i64v.set (&mut selectors) 0 0)
      (i64v.set (&mut selectors) 1 1)
      (i64v.set (&mut selectors) 2 3)
      (let
        [selector-slots (i64v.slots (& selectors))]
        [out-slots (i64v.slots-mut (&mut out))]
        (foreach
          ([i : i64 0 n])
          (array-set!
            out-slots
            i
            (spmd-shuffle (cast 77 : i64) (array-ref selector-slots i)))))
      0)))