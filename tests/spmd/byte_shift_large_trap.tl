;; #6686: one active u8 count equal to the lane width in masked value lowering
;; must use tl_shift_abort (exit 129).

(define (main) : i64
  (let
    [n : i64 77]
    [xs : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [counts : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref xs i) (cast (+ (% i 127) 1) : u8))
          (set!
            (array-ref counts i)
            (if (= i 40)
              8
              1))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : u8 (array-ref xs j)]
          (set!
            (array-ref out j)
            (if (> x 0)
              (shl x (array-ref counts j))
              x))))
      42)))