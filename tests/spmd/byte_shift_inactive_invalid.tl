;; #6686: invalid byte counts in inactive branch lanes and backing tail lanes
;; are unobservable in both signed and unsigned masked value lowering.
(define (main) : i64
  (let
    [n : i64 77]
    [capacity : i64 96]
    [signed-xs : (__tl_dyn-array i8) (__tl_make-array i8 capacity)]
    [signed-counts : (__tl_dyn-array i8) (__tl_make-array i8 capacity)]
    [signed-out : (__tl_dyn-array i8) (__tl_make-array i8 capacity)]
    [unsigned-xs : (__tl_dyn-array u8) (__tl_make-array u8 capacity)]
    [unsigned-counts : (__tl_dyn-array u8) (__tl_make-array u8 capacity)]
    [unsigned-out : (__tl_dyn-array u8) (__tl_make-array u8 capacity)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i capacity)
        (begin
          (set! (array-ref signed-xs i) (cast (- (% i 63) 31) : i8))
          (set! (array-ref unsigned-xs i) (cast (+ (% i 127) 1) : u8))
          (set!
            (array-ref signed-counts i)
            (if (and (< i n) (= (bit-and (array-ref signed-xs i) 1) 1))
              1
              -1))
          (set!
            (array-ref unsigned-counts i)
            (if (and (< i n) (= (bit-and (array-ref unsigned-xs i) 1) 1))
              1
              8))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : i8 (array-ref signed-xs j)]
          (set!
            (array-ref signed-out j)
            (if (= (bit-and x 1) 1)
              (shr x (array-ref signed-counts j))
              x))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : u8 (array-ref unsigned-xs j)]
          (set!
            (array-ref unsigned-out j)
            (if (= (bit-and x 1) 1)
              (shl x (array-ref unsigned-counts j))
              x))))
      (set! i 0)
      (while (and ok (< i n))
        (begin
          (unless
            (=
              (array-ref signed-out i)
              (if (= (bit-and (array-ref signed-xs i) 1) 1)
                (shr (array-ref signed-xs i) 1)
                (array-ref signed-xs i)))
            (set! ok false))
          (unless
            (=
              (array-ref unsigned-out i)
              (if (= (bit-and (array-ref unsigned-xs i) 1) 1)
                (shl (array-ref unsigned-xs i) 1)
                (array-ref unsigned-xs i)))
            (set! ok false))
          (set! i (+ i 1))))
      (if ok
        42
        1))))