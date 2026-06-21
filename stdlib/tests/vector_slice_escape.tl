(import stdlib.vector)
(import stdlib.vector_slice)
(import (stdlib.vector.vector i64) as vec)
(import (stdlib.vector_slice.slice i64) as slice)

; Must fail: the returned slice is tied to `inner`, not `outer`.
(define (main [outer : vec.Vec]) : (slice.Slice outer)
  (let
    [inner : vec.Vec (vec.new)]
    (begin
      (vec.push (&mut inner) 10)
      (slice.from-vec (& inner) 0 1))))