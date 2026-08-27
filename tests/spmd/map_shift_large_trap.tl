;; #5679: one active count equal to the u32 width in a direct map must use
;; tl_shift_abort (exit 129).
(define (main) : i64
  (let
    [n : i64 19]
    [xs : (__tl_dyn-array u32) (__tl_make-array u32 n)]
    [counts : (__tl_dyn-array u32) (__tl_make-array u32 n)]
    [out : (__tl_dyn-array u32) (__tl_make-array u32 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref xs i) (cast (+ i 1) : u32))
          (set!
            (array-ref counts i)
            (if (= i 6)
              32
              1))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (set! (array-ref out j) (shl (array-ref xs j) (array-ref counts j))))
      42)))