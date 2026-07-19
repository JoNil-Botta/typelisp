; Active selectors are signed i64 values. A negative selector in the second
; logical destination lane must take the standard bounds-abort path.
(import stdlib.array)

(define (main) : i64
  (let
    [n : i64 2]
    [xs : (Array i64) (array.make-array i64 n)]
    [selectors : (Array i64) (array.make-array i64 n)]
    [out : (Array i64) (array.make-array i64 n)]
    (begin
      (array-set! xs 0 11)
      (array-set! xs 1 22)
      (array-set! selectors 0 0)
      (array-set! selectors 1 -1)
      (foreach
        ([i : i64 0 n])
        (array-set!
          out
          i
          (spmd-shuffle (array-ref xs i) (array-ref selectors i))))
      0)))