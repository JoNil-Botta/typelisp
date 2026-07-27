;; #5679: one active negative i64 count in a direct map must use
;; tl_shift_abort (exit 129).
(import stdlib.array)

(define (main) : i64
  (let
    [n : i64 13]
    [xs : (Array i64) (array.make-array i64 n)]
    [counts : (Array i64) (array.make-array i64 n)]
    [out : (Array i64) (array.make-array i64 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (- i 7))
          (array-set!
            counts
            i
            (if (= i 5)
              -1
              1))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (array-set! out j (shr (array-ref xs j) (array-ref counts j))))
      42)))