; A computed identity selector must mask its inactive tail lanes before the
; whole-gang selector check. The inactive lane IDs are out of range for this
; three-lane gang, while every active selector remains valid.
(import stdlib.vector)
(import (vector.vector i64) as i64v)
(import spmd_vec_support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)

(define (main) : i64
  (let
    [n : i64 3]
    [xs : i64v.Vec (i64z.make n)]
    [out : i64v.Vec (i64z.make n)]
    (begin
      (i64v.set-ref! (&mut xs) 0 11)
      (i64v.set-ref! (&mut xs) 1 22)
      (i64v.set-ref! (&mut xs) 2 33)
      (let
        [xs-slots (i64v.slots (& xs))]
        [out-slots (i64v.slots-mut (&mut out))]
        (foreach
          ([i : i64 0 n])
          (set!
            (array-ref out-slots i)
            (spmd-shuffle (array-ref xs-slots i) (+ (program-index) 0)))))
      (if (and
        (= (i64v.get (& out) 0 0) 11)
        (= (i64v.get (& out) 1 0) 22)
        (= (i64v.get (& out) 2 0) 33))
        42
        1))))