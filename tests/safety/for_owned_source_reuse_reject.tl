(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (main) : i64
  (let
    [values : vec.Vec (vec.new)]
    (begin
      (for [item : i64 values] unit)
      (vec.len (& values)))))