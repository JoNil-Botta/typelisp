(import stdlib.vector)
(import (stdlib.vector.vector i64) as vec)

; Must fail: the returned slice is tied to `inner`, not `outer`.
(define (main [outer : vec.Vec]) : (& outer (Slice i64))
  (let
    [inner : vec.Vec (vec.new)]
    (begin
      (vec.push-ref! (&mut inner) 10)
      (vec.view (& inner)))))