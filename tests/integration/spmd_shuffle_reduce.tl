; The shared shuffle value plan is also consumed by vectorized reduction.
(import stdlib.vector)
(import (vector.vector i64) as i64v)
(import spmd_vec_support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)

(define (main) : i64
  (let
    [n : i64 19]
    [xs : i64v.Vec (i64z.make n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (i64v.set (&mut xs) i (+ (* i 3) 1))
          (set! i (+ i 1))))
      (if (=
        (let
          [xs-slots (i64v.slots (& xs))]
          (spmd-reduce
            sum
            ([j : i64 0 n])
            0
            (spmd-shuffle (array-ref xs-slots j) (program-index))))
        532)
        42
        1))))