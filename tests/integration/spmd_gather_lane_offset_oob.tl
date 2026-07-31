(import stdlib.vector)
(import (vector.vector i64) as i64v)
(import spmd_vec_support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)

;; Lane 0 overflows `i + offset` from i64::MAX to i64::MIN. Checked lowering
;; must preserve signed wrapping arithmetic, validate in logical lane order,
;; and abort before issuing the hardware gather. The later negative lane also
;; verifies that no gather runs after the first invalid active lane.
(define (main) : i64
  (let
    [xs : i64v.Vec (i64z.make 8)]
    [offsets : i64v.Vec (i64z.make 16)]
    [out : i64v.Vec (i64z.make 9)]
    (begin
      (i64v.set (&mut offsets) 0 9223372036854775807)
      (i64v.set (&mut offsets) 1 0)
      (i64v.set (&mut offsets) 2 0)
      (i64v.set (&mut offsets) 3 (- 0 7))
      (let
        [xs-slots (i64v.slots (& xs))]
        [offset-slots (i64v.slots (& offsets))]
        [out-slots (i64v.slots-mut (&mut out))]
        (foreach
          ([i : i64 1 9])
          (array-set!
            out-slots
            i
            (array-ref xs-slots (+ i (array-ref offset-slots (program-index)))))))
      1)))