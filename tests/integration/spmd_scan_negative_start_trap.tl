; A negative active scan start must retain the ordinary array bounds abort.
; AVX2 must enter the scalar path without overflowing its gang-width add.
(import stdlib.vector)
(import (vector.vector i64) as i64v)
(import "spmd_vec_support.tl" module spmd.vec.support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)

(define (main) : i64
  (let
    [xs : i64v.Vec (i64z.make 4)]
    [out : i64v.Vec (i64z.make 4)]
    (let
      [xs-slots (i64v.slots (& xs))]
      [out-slots (i64v.slots-mut (&mut out))]
      (begin
        (spmd-scan
          sum
          ([i : i64 (- 0 1) 3] [prefix : i64 0])
          (array-ref xs-slots i)
          (array-set! out-slots i prefix))
        42))))