(import stdlib.vector)
(import (vector.vector i64) as i64v)
(import spmd_vec_support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)

;; Two active lanes are invalid. SIMD lowering must validate in logical lane
;; order and abort before issuing the gather; lane 1 is therefore the selected
;; failure even when both invalid indexes share one hardware gang.
(define (main) : i64
  (let
    [xs : i64v.Vec (i64z.make 8)]
    [ix : i64v.Vec (i64z.make 8)]
    [out : i64v.Vec (i64z.make 8)]
    (begin
      (i64v.set (&mut ix) 0 0)
      (i64v.set (&mut ix) 1 9223372036854775807)
      (i64v.set (&mut ix) 2 1)
      (i64v.set (&mut ix) 3 (- 0 1))
      (i64v.set (&mut ix) 4 2)
      (i64v.set (&mut ix) 5 3)
      (i64v.set (&mut ix) 6 4)
      (i64v.set (&mut ix) 7 5)
      (let
        [xs-slots (i64v.slots (& xs))]
        [ix-slots (i64v.slots (& ix))]
        [out-slots (i64v.slots-mut (&mut out))]
        (foreach
          ([i : i64 0 8])
          (array-set! out-slots i (array-ref xs-slots (array-ref ix-slots i)))))
      1)))