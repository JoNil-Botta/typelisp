;; #6685: one active negative i16 count in a direct map must use
;; tl_shift_abort (exit 129).
(import stdlib.array)

(define (main) : i64
  (let
    [n : i64 77]
    [xs : (__tl_dyn-array i16) (array.make-array i16 n)]
    [counts : (__tl_dyn-array i16) (array.make-array i16 n)]
    [out : (__tl_dyn-array i16) (array.make-array i16 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref xs i) (cast (- (% i 257) 128) : i16))
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