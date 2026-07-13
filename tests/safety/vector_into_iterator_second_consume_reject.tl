(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (main) : i64
  (let
    [values : vec.Vec (vec.new)]
    [first : vec.IntoIter (vec.into-iterator values)]
    [second : vec.IntoIter (vec.into-iterator values)]
    (+
      (if (match (vec.into-next (&mut first))
        [(vec.IntoNext.Done) true]
        [(vec.IntoNext.Item _) false])
        1
        0)
      (if (match (vec.into-next (&mut second))
        [(vec.IntoNext.Done) true]
        [(vec.IntoNext.Item _) false])
        1
        0))))