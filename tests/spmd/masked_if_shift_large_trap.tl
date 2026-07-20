;; #5365: one active count equal to the u32 width must use tl_shift_abort.
(import stdlib.array)

(define (main) : i64
  (let
    [n : i64 19]
    [xs : (Array u32) (array.make-array u32 n)]
    [counts : (Array u32) (array.make-array u32 n)]
    [out : (Array u32) (array.make-array u32 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (cast (+ i 1) : u32))
          (array-set!
            counts
            i
            (if (= i 6)
              32
              1))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : u32 (array-ref xs j)]
          (array-set!
            out
            j
            (if (= (bit-and x 1) 1)
              (shl x (array-ref counts j))
              x))))
      42)))