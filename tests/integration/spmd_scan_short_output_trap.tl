; One full AVX2 gang may complete, but a short output must still trap at the
; first scalar-tail store instead of writing beyond the destination.
(import stdlib.array)

(define (main) : i64
  (let
    [xs : (Array i64) (array.make-array i64 8)]
    [out : (Array i64) (array.make-array i64 6)]
    (begin
      (spmd-scan
        sum
        ([i : i64 0 8] [prefix : i64 0])
        (array-ref xs i)
        (array-set! out i prefix))
      42)))