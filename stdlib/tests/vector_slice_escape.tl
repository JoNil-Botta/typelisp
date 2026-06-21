(import "stdlib/vector_slice.tl")
(import (vector i64) as vec)
(import (slice i64) as slice)

; Must fail: the returned slice is tied to `inner`, not `outer`.
(define (main [outer : vec.Vec]) : (slice.Slice outer)
  (let
    [inner : vec.Vec (vec.new)]
    (begin
      (vec.push (&mut inner) 10)
      (slice.from-vec (& inner) 0 1))))