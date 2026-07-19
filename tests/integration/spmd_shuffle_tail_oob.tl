; In a three-lane tail gang, selector 3 names an inactive source lane and must
; trap. The uniform source makes sure validation cannot be optimized away.
(import stdlib.array)

(define (main) : i64
  (let
    [n : i64 3]
    [selectors : (Array i64) (array.make-array i64 n)]
    [out : (Array i64) (array.make-array i64 n)]
    (begin
      (array-set! selectors 0 0)
      (array-set! selectors 1 1)
      (array-set! selectors 2 3)
      (foreach
        ([i : i64 0 n])
        (array-set!
          out
          i
          (spmd-shuffle (cast 77 : i64) (array-ref selectors i))))
      0)))