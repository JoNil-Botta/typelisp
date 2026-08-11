;; #5365: one active count equal to the u32 width must use tl_shift_abort.
(import stdlib.array)

(define (main) : i64
  (let
    [n : i64 19]
    [xs : (__tl_dyn-array u32) (array.make-array u32 n)]
    [counts : (__tl_dyn-array u32) (array.make-array u32 n)]
    [out : (__tl_dyn-array u32) (array.make-array u32 n)]
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
        (let
          [x : u32 (array-ref xs j)]
          (set!
            (array-ref out j)
            (if (= (bit-and x 1) 1)
              (shl x (array-ref counts j))
              x))))
      42)))