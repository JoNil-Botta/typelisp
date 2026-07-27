;; Direct contiguous-map shifts (#5679): all supported lane types, varying
;; counts, signed/logical right shift, full gangs, and partial tails. Backing
;; lanes beyond each logical range contain invalid counts; AVX-512 predicated
;; tails must not let those inactive counts reach the shift guard.
(import stdlib.array)

(define (case-i32) : bool
  (let
    [n : i64 19]
    [capacity : i64 32]
    [xs : (Array i32) (array.make-array i32 capacity)]
    [counts : (Array i32) (array.make-array i32 capacity)]
    [left : (Array i32) (array.make-array i32 capacity)]
    [right : (Array i32) (array.make-array i32 capacity)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i capacity)
        (begin
          (array-set! xs i (cast (- i 9) : i32))
          (array-set!
            counts
            i
            (if (< i n)
              (cast (% i 31) : i32)
              (cast 32 : i32)))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (begin
          (array-set! left j (shl (array-ref xs j) (array-ref counts j)))
          (array-set! right j (shr (array-ref xs j) (array-ref counts j)))))
      (set! i 0)
      (while (and ok (< i n))
        (begin
          (unless
            (= (array-ref left i) (shl (array-ref xs i) (array-ref counts i)))
            (set! ok false))
          (unless
            (= (array-ref right i) (shr (array-ref xs i) (array-ref counts i)))
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (case-u32) : bool
  (let
    [n : i64 19]
    [capacity : i64 32]
    [xs : (Array u32) (array.make-array u32 capacity)]
    [counts : (Array u32) (array.make-array u32 capacity)]
    [left : (Array u32) (array.make-array u32 capacity)]
    [right : (Array u32) (array.make-array u32 capacity)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i capacity)
        (begin
          (array-set! xs i (cast (+ (* i 17) 3) : u32))
          (array-set!
            counts
            i
            (if (< i n)
              (cast (% i 31) : u32)
              (cast 32 : u32)))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (begin
          (array-set! left j (shl (array-ref xs j) (array-ref counts j)))
          (array-set! right j (shr (array-ref xs j) (array-ref counts j)))))
      (set! i 0)
      (while (and ok (< i n))
        (begin
          (unless
            (= (array-ref left i) (shl (array-ref xs i) (array-ref counts i)))
            (set! ok false))
          (unless
            (= (array-ref right i) (shr (array-ref xs i) (array-ref counts i)))
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (case-i64) : bool
  (let
    [n : i64 13]
    [capacity : i64 16]
    [xs : (Array i64) (array.make-array i64 capacity)]
    [counts : (Array i64) (array.make-array i64 capacity)]
    [left : (Array i64) (array.make-array i64 capacity)]
    [right : (Array i64) (array.make-array i64 capacity)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i capacity)
        (begin
          (array-set! xs i (- i 7))
          (array-set!
            counts
            i
            (if (< i n)
              (% i 63)
              (cast 64 : i64)))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (begin
          (array-set! left j (shl (array-ref xs j) (array-ref counts j)))
          (array-set! right j (shr (array-ref xs j) (array-ref counts j)))))
      (set! i 0)
      (while (and ok (< i n))
        (begin
          (unless
            (= (array-ref left i) (shl (array-ref xs i) (array-ref counts i)))
            (set! ok false))
          (unless
            (= (array-ref right i) (shr (array-ref xs i) (array-ref counts i)))
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (case-u64) : bool
  (let
    [n : i64 13]
    [capacity : i64 16]
    [xs : (Array u64) (array.make-array u64 capacity)]
    [counts : (Array u64) (array.make-array u64 capacity)]
    [left : (Array u64) (array.make-array u64 capacity)]
    [right : (Array u64) (array.make-array u64 capacity)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i capacity)
        (begin
          (array-set! xs i (cast (+ (* i 31) 5) : u64))
          (array-set!
            counts
            i
            (if (< i n)
              (cast (% i 63) : u64)
              (cast 64 : u64)))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (begin
          (array-set! left j (shl (array-ref xs j) (array-ref counts j)))
          (array-set! right j (shr (array-ref xs j) (array-ref counts j)))))
      (set! i 0)
      (while (and ok (< i n))
        (begin
          (unless
            (= (array-ref left i) (shl (array-ref xs i) (array-ref counts i)))
            (set! ok false))
          (unless
            (= (array-ref right i) (shr (array-ref xs i) (array-ref counts i)))
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (main) : i64
  (cond
    [(not (case-i32)) 1]
    [(not (case-u32)) 2]
    [(not (case-i64)) 3]
    [(not (case-u64)) 4]
    [else 42]))