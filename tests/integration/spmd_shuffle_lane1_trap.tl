; Scalar reference semantics: lane 1 is out of bounds because scalar gangs
; have exactly one active lane.
; Compatibility exception for #3772: spmd-shuffle value expressions still use
; bare `array-ref` so the checker sees the compiler array-read AST.
(import stdlib.vector)
(import (vector.vector i64) as i64v)
(import "spmd_vec_support.tl" module spmd.vec.support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)

(define (main) : i64
  (let
    [xs : i64v.Vec (i64z.make 1)]
    [out : i64v.Vec (i64z.make 1)]
    (begin
      (i64v.set (&mut xs) 0 7)
      (let
        [xs-slots (i64v.slots (& xs))]
        [out-slots (i64v.slots-mut (&mut out))]
        (foreach
          ([i : i64 0 1])
          (array-set! out-slots i (spmd-shuffle (array-ref xs-slots i) 1))))
      0)))