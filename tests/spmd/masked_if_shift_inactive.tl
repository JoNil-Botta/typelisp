;; #5365: invalid counts in inactive branch and tail lanes are unobservable.

(define (main) : i64
  (let
    [n : i64 19]
    [total : i64 24]
    [xs : (__tl_dyn-array i32) (__tl_make-array i32 total)]
    [counts : (__tl_dyn-array i32) (__tl_make-array i32 total)]
    [out : (__tl_dyn-array i32) (__tl_make-array i32 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i total)
        (begin
          (set! (array-ref xs i) (cast (+ i 1) : i32))
          (set!
            (array-ref counts i)
            (if (= (% i 2) 0)
              (cast (% i 4) : i32)
              32))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : i32 (array-ref xs j)]
          [count : i32 (array-ref counts j)]
          (set!
            (array-ref out j)
            (if (= (bit-and x 1) 1)
              (shl x count)
              x))))
      (set! i 0)
      (while (< i n)
        (let
          [x : i32 (array-ref xs i)]
          [want : i32
            (if (= (bit-and x 1) 1)
              (shl x (array-ref counts i))
              x)]
          (begin
            (if (!= (array-ref out i) want)
              (set! ok false)
              unit)
            (set! i (+ i 1)))))
      (if ok
        42
        1))))