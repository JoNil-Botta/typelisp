(import "stdlib/vector_slice.tl")

; Must fail: the returned slice is tied to `inner`, not `outer`.
(define (main [outer : I64Vec]) : (I64Slice outer)
  (let
    [inner : I64Vec (i64-vec-push (i64-vec-new) 10)]
    (i64-slice-from-vec inner (& inner) 0 1)))