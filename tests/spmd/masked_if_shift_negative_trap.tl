;; #5365: one active negative i64 count must use tl_shift_abort (exit 129).
(define (main) : i64
  (let
    [n : i64 13]
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [counts : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref xs i) (- i 7))
          (set!
            (array-ref counts i)
            (if (= i 5)
              -1
              1))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : i64 (array-ref xs j)]
          (set!
            (array-ref out j)
            (if (< x 0)
              (shr x (array-ref counts j))
              x))))
      42)))