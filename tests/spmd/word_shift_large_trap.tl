;; #6685: one active u16 count equal to the lane width in masked value
;; lowering must use tl_shift_abort (exit 129).

(define (main) : i64
  (let
    [n : i64 77]
    [xs : (__tl_dyn-array u16) (__tl_make-array u16 n)]
    [counts : (__tl_dyn-array u16) (__tl_make-array u16 n)]
    [out : (__tl_dyn-array u16) (__tl_make-array u16 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref xs i) (cast (+ (% i 32767) 1) : u16))
          (set!
            (array-ref counts i)
            (if (= i 40)
              16
              1))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : u16 (array-ref xs j)]
          (set!
            (array-ref out j)
            (if (> x 0)
              (shl x (array-ref counts j))
              x))))
      42)))