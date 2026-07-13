(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (main) : i64
  (let
    [values : vec.Vec (vec.new)]
    [iter : vec.IntoIter (vec.into-iterator values)]
    (begin
      (vec.into-next (&mut iter))
      (vec.push (&mut values) 1)
      0)))