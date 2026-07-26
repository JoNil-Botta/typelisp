;; Enum matches whose varying source is not a contiguous array lane must use
;; the documented SIMD diagnostic instead of silently selecting scalar foreach.
(import stdlib.array)

(defenum Choice
  (Zero)
  (One))

(define (read-choice [items : (Array Choice)] [i : i64]) : Choice
  (array-ref items i))

(define (main) : i64
  (let
    [items : (Array Choice) (array.make-array Choice 2)]
    [out : (Array i64) (array.make-array i64 2)]
    (begin
      (array-set! items 0 Zero)
      (array-set! items 1 One)
      (foreach
        ([i : i64 0 2])
        (array-set!
          out
          i
          (match (read-choice items i)
            [Zero 11]
            [One 31])))
      (if (and (= (array-ref out 0) 11) (= (array-ref out 1) 31))
        42
        1))))