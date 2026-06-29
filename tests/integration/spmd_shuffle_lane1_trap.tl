; Scalar reference semantics: lane 1 is out of bounds because scalar gangs
; have exactly one active lane.
; Compatibility exception for #3772: spmd-shuffle value expressions still use
; bare `array-ref` so the checker sees the compiler array-read AST.
(import stdlib.array)

(define (main) : i64
  (let
    [xs : (Array i64) (array.make-array i64 1)]
    [out : (Array i64) (array.make-array i64 1)]
    (begin
      (array-set! xs 0 7)
      (foreach
        ([i : i64 0 1])
        (array-set! out i (spmd-shuffle (array-ref xs i) 1)))
      0)))