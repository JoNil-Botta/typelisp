; One full AVX2 gang may complete, but a short output must still trap at the
; first scalar-tail store instead of writing beyond the destination.
(import stdlib.vector)
(import (vector.vector i64) as i64v)
(import "spmd_vec_support.tl" module spmd.vec.support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)

(define (main) : i64
  (let
    [xs : i64v.Vec (i64z.make 8)]
    [out : i64v.Vec (i64z.make 6)]
    (let
      [xs-slots (i64v.slots (& xs))]
      [out-slots (i64v.slots-mut (&mut out))]
      (begin
        (spmd-scan
          sum
          ([i : i64 0 8] [prefix : i64 0])
          (array-ref xs-slots i)
          (array-set! out-slots i prefix))
        42))))