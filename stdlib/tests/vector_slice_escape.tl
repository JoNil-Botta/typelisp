(import stdlib.vector_slice)

; Must fail: the returned slice is tied to `inner`, not `outer`.
(define (main [outer : I64Vec]) : (vector_slice.I64Slice outer)
  (let
    [inner : I64Vec (i64-vec-push (i64-vec-new) 10)]
    (vector_slice.i64-slice-from-vec inner (& inner) 0 1)))