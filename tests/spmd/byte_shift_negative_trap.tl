;; #6686: one active negative i8 count in a direct map must use
;; tl_shift_abort (exit 129).
(define (main) : i64
  (let
    [n : i64 77]
    [xs : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [counts : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [out : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref xs i) (cast (- (% i 17) 8) : i8))
          (set!
            (array-ref counts i)
            (if (= i 37)
              -1
              1))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (set! (array-ref out j) (shr (array-ref xs j) (array-ref counts j))))
      42)))