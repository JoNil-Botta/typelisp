; The shared shuffle value plan is also consumed by vectorized reduction.
(import stdlib.array)

(define (main) : i64
  (let
    [n : i64 19]
    [xs : (Array i64) (array.make-array i64 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (+ (* i 3) 1))
          (set! i (+ i 1))))
      (if (=
        (spmd-reduce
          sum
          ([j : i64 0 n])
          0
          (spmd-shuffle (array-ref xs j) (program-index)))
        532)
        42
        1))))