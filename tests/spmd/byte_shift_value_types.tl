;; Checked byte-lane shifts (#6686): direct maps and nested masked values use
;; the same scalar semantics across empty, short, full, multi-gang, and tail
;; lengths. Backing tail lanes carry invalid counts and must stay inactive.
(define (count-i8 [i : i64]) : i8
  (match (% i 4)
    [0 0]
    [1 1]
    [2 6]
    [_ 7]))

(define (count-u8 [i : i64]) : u8
  (cast (count-i8 i) : u8))

(define (run-direct-i8 [n : i64]) : bool
  (let
    [capacity : i64 96]
    [xs : (__tl_dyn-array i8) (__tl_make-array i8 capacity)]
    [counts : (__tl_dyn-array i8) (__tl_make-array i8 capacity)]
    [left : (__tl_dyn-array i8) (__tl_make-array i8 capacity)]
    [right : (__tl_dyn-array i8) (__tl_make-array i8 capacity)]
    [literal : (__tl_dyn-array i8) (__tl_make-array i8 capacity)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i capacity)
        (begin
          (set! (array-ref xs i) (cast (- (% (* i 37) 256) 128) : i8))
          (set!
            (array-ref counts i)
            (if (< i n)
              (count-i8 i)
              8))
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

(define (run-direct-u8 [n : i64]) : bool
  (let
    [capacity : i64 96]
    [xs : (__tl_dyn-array u8) (__tl_make-array u8 capacity)]
    [counts : (__tl_dyn-array u8) (__tl_make-array u8 capacity)]
    [left : (__tl_dyn-array u8) (__tl_make-array u8 capacity)]
    [right : (__tl_dyn-array u8) (__tl_make-array u8 capacity)]
    [literal : (__tl_dyn-array u8) (__tl_make-array u8 capacity)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i capacity)
        (begin
          (set! (array-ref xs i) (cast (% (+ (* i 53) 129) 256) : u8))
          (set!
            (array-ref counts i)
            (if (< i n)
              (count-u8 i)
              8))
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

(define (run-masked-i8) : bool
  (let
    [n : i64 77]
    [xs : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [counts : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [out : (__tl_dyn-array i8) (__tl_make-array i8 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref xs i) (cast (- (% (* i 41) 256) 128) : i8))
          (set! (array-ref counts i) (count-i8 i))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : i8 (array-ref xs j)]
          [count : i8 (array-ref counts j)]
          (set!
            (array-ref out j)
            (if (< x 0)
              (shr x count)
              (if (= (bit-and x 2) 0)
                (shl x count)
                (shl x 1))))))
      (set! i 0)
      (while (and ok (< i n))
        (let
          [x : i8 (array-ref xs i)]
          [count : i8 (array-ref counts i)]
          [want : i8
            (if (< x 0)
              (shr x count)
              (if (= (bit-and x 2) 0)
                (shl x count)
                (shl x 1)))]
          (begin
            (unless (= (array-ref out i) want) (set! ok false))
            (set! i (+ i 1)))))
      ok)))

(define (run-masked-u8) : bool
  (let
    [n : i64 77]
    [xs : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [counts : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref xs i) (cast (% (+ (* i 59) 131) 256) : u8))
          (set! (array-ref counts i) (count-u8 i))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : u8 (array-ref xs j)]
          [count : u8 (array-ref counts j)]
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
          [x : u8 (array-ref xs i)]
          [count : u8 (array-ref counts i)]
          [want : u8
            (if (= (bit-and x 1) 0)
              (shr x count)
              (if (= (bit-and x 2) 0)
                (shl x count)
                (shr x 1)))]
          (begin
            (unless (= (array-ref out i) want) (set! ok false))
            (set! i (+ i 1)))))
      ok)))

(define (main) : i64
  (begin
    (unless (run-direct-i8 0) (return 1))
    (unless (run-direct-i8 7) (return 2))
    (unless (run-direct-i8 32) (return 3))
    (unless (run-direct-i8 64) (return 4))
    (unless (run-direct-i8 77) (return 5))
    (unless (run-direct-u8 0) (return 6))
    (unless (run-direct-u8 7) (return 7))
    (unless (run-direct-u8 32) (return 8))
    (unless (run-direct-u8 64) (return 9))
    (unless (run-direct-u8 77) (return 10))
    (unless (run-masked-i8) (return 11))
    (unless (run-masked-u8) (return 12))
    42))