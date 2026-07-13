(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (main) : i64
  (let
    [values : vec.Vec (vec.new)]
    [borrowed : (& values vec.Vec) (& values)]
    [iter : vec.IntoIter (vec.into-iterator values)]
    (+
      (vec.len borrowed)
      (match (vec.into-next (&mut iter))
        [(vec.IntoNext.Done) 0]
        [(vec.IntoNext.Item _) 1]))))