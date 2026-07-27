;; #5679: one active count equal to the u32 width in a direct map must use
;; tl_shift_abort (exit 129).
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
        (array-set! out j (shl (array-ref xs j) (array-ref counts j))))
      42)))