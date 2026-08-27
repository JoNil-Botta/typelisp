;; Checked word-lane shifts (#6685): direct maps and nested masked values use
;; the same scalar semantics across empty, short, full, multi-gang, and tail
;; lengths. Backing tail lanes carry invalid counts and must stay inactive.

(define (count-i16 [i : i64]) : i16
  (match (% i 4)
    [0 0]
    [1 1]
    [2 14]
    [_ 15]))

(define (count-u16 [i : i64]) : u16
  (cast (count-i16 i) : u16))

(define (run-direct-i16 [n : i64]) : bool
  (let
    [capacity : i64 96]
    [xs : (__tl_dyn-array i16) (__tl_make-array i16 capacity)]
    [counts : (__tl_dyn-array i16) (__tl_make-array i16 capacity)]
    [left : (__tl_dyn-array i16) (__tl_make-array i16 capacity)]
    [right : (__tl_dyn-array i16) (__tl_make-array i16 capacity)]
    [literal : (__tl_dyn-array i16) (__tl_make-array i16 capacity)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i capacity)
        (begin
          (set! (array-ref xs i) (cast (- (% (* i 12347) 65536) 32768) : i16))
          (set!
            (array-ref counts i)
            (if (< i n)
              (count-i16 i)
              16))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (begin
          (set! (array-ref left j) (shl (array-ref xs j) (array-ref counts j)))
          (set! (array-ref right j) (shr (array-ref xs j) (array-ref counts j)))
          (set! (array-ref literal j) (shl (array-ref xs j) 1))))
      (set! i 0)
      (while (and ok (< i n))
        (begin
          (unless
            (= (array-ref left i) (shl (array-ref xs i) (array-ref counts i)))
            (set! ok false))
          (unless
            (= (array-ref right i) (shr (array-ref xs i) (array-ref counts i)))
            (set! ok false))
          (unless
            (= (array-ref literal i) (shl (array-ref xs i) 1))
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (run-direct-u16 [n : i64]) : bool
  (let
    [capacity : i64 96]
    [xs : (__tl_dyn-array u16) (__tl_make-array u16 capacity)]
    [counts : (__tl_dyn-array u16) (__tl_make-array u16 capacity)]
    [left : (__tl_dyn-array u16) (__tl_make-array u16 capacity)]
    [right : (__tl_dyn-array u16) (__tl_make-array u16 capacity)]
    [literal : (__tl_dyn-array u16) (__tl_make-array u16 capacity)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i capacity)
        (begin
          (set! (array-ref xs i) (cast (% (+ (* i 40503) 32769) 65536) : u16))
          (set!
            (array-ref counts i)
            (if (< i n)
              (count-u16 i)
              16))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (begin
          (set! (array-ref left j) (shl (array-ref xs j) (array-ref counts j)))
          (set! (array-ref right j) (shr (array-ref xs j) (array-ref counts j)))
          (set! (array-ref literal j) (shr (array-ref xs j) 1))))
      (set! i 0)
      (while (and ok (< i n))
        (begin
          (unless
            (= (array-ref left i) (shl (array-ref xs i) (array-ref counts i)))
            (set! ok false))
          (unless
            (= (array-ref right i) (shr (array-ref xs i) (array-ref counts i)))
            (set! ok false))
          (unless
            (= (array-ref literal i) (shr (array-ref xs i) 1))
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (run-masked-i16) : bool
  (let
    [n : i64 77]
    [xs : (__tl_dyn-array i16) (__tl_make-array i16 n)]
    [counts : (__tl_dyn-array i16) (__tl_make-array i16 n)]
    [out : (__tl_dyn-array i16) (__tl_make-array i16 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref xs i) (cast (- (% (* i 16001) 65536) 32768) : i16))
          (set! (array-ref counts i) (count-i16 i))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : i16 (array-ref xs j)]
          [count : i16 (array-ref counts j)]
          (set!
            (array-ref out j)
            (if (< x 0)
              (shr x count)
              (match (bit-and x 3)
                [0 (shl x count)]
                [1 (shr x 1)]
                [_
                  (if (= (bit-and x 4) 0)
                    (shl x 1)
                    (shr x count))])))))
      (set! i 0)
      (while (and ok (< i n))
        (let
          [x : i16 (array-ref xs i)]
          [count : i16 (array-ref counts i)]
          [want : i16
            (if (< x 0)
              (shr x count)
              (match (bit-and x 3)
                [0 (shl x count)]
                [1 (shr x 1)]
                [_
                  (if (= (bit-and x 4) 0)
                    (shl x 1)
                    (shr x count))]))]
          (begin
            (unless (= (array-ref out i) want) (set! ok false))
            (set! i (+ i 1)))))
      ok)))

(define (run-masked-u16) : bool
  (let
    [n : i64 77]
    [xs : (__tl_dyn-array u16) (__tl_make-array u16 n)]
    [counts : (__tl_dyn-array u16) (__tl_make-array u16 n)]
    [out : (__tl_dyn-array u16) (__tl_make-array u16 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref xs i) (cast (% (+ (* i 50021) 32771) 65536) : u16))
          (set! (array-ref counts i) (count-u16 i))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : u16 (array-ref xs j)]
          [count : u16 (array-ref counts j)]
          (set!
            (array-ref out j)
            (if (= (bit-and x 1) 0)
              (shr x count)
              (if (= (bit-and x 2) 0)
                (shl x count)
                (shr x 1))))))
      (set! i 0)
      (while (and ok (< i n))
        (let
          [x : u16 (array-ref xs i)]
          [count : u16 (array-ref counts i)]
          [want : u16
            (if (= (bit-and x 1) 0)
              (shr x count)
              (if (= (bit-and x 2) 0)
                (shl x count)
                (shr x 1)))]
          (begin
            (unless (= (array-ref out i) want) (set! ok false))
            (set! i (+ i 1)))))
      ok)))

(define (run-masked-while-u16) : bool
  (let
    [n : i64 77]
    [xs : (__tl_dyn-array u16) (__tl_make-array u16 n)]
    [work : (__tl_dyn-array u16) (__tl_make-array u16 n)]
    [out : (__tl_dyn-array u16) (__tl_make-array u16 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref xs i) (cast (+ (% i 4095) 1) : u16))
          (set! (array-ref work i) (cast (% i 4) : u16))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : u16 (array-ref xs j)]
          (if (= (bit-and x 1) 1)
            (begin
              (set! (array-ref out j) x)
              (while (> (array-ref work j) 0)
                (begin
                  (set! (array-ref out j) (shl (array-ref out j) 1))
                  (set! (array-ref work j) (- (array-ref work j) 1)))))
            (set! (array-ref out j) x))))
      (set! i 0)
      (while (and ok (< i n))
        (let
          [x : u16 (array-ref xs i)]
          [steps : u16 (cast (% i 4) : u16)]
          [want : u16
            (if (= (bit-and x 1) 1)
              (shl x steps)
              x)]
          (begin
            (unless (= (array-ref out i) want) (set! ok false))
            (set! i (+ i 1)))))
      ok)))

(define (main) : i64
  (begin
    (unless (run-direct-i16 0) (return 1))
    (unless (run-direct-i16 7) (return 2))
    (unless (run-direct-i16 16) (return 3))
    (unless (run-direct-i16 32) (return 4))
    (unless (run-direct-i16 64) (return 5))
    (unless (run-direct-i16 77) (return 6))
    (unless (run-direct-u16 0) (return 7))
    (unless (run-direct-u16 7) (return 8))
    (unless (run-direct-u16 16) (return 9))
    (unless (run-direct-u16 32) (return 10))
    (unless (run-direct-u16 64) (return 11))
    (unless (run-direct-u16 77) (return 12))
    (unless (run-masked-i16) (return 13))
    (unless (run-masked-u16) (return 14))
    (unless (run-masked-while-u16) (return 15))
    42))