;; SPMD masked-shift corpus (#5365): native dword/qword shifts, varying and
;; literal counts, signed/logical right shift, nested masks, and partial tails.
(import stdlib.array)

(define (count32 [i : i64]) : i32
  (match (% i 4)
    [0 0]
    [1 1]
    [2 30]
    [_ 31]))

(define (count64 [i : i64]) : i64
  (match (% i 4)
    [0 0]
    [1 1]
    [2 62]
    [_ 63]))

(define (case-i32) : bool
  (let
    [n : i64 19]
    [xs : (Array i32) (array.make-array i32 n)]
    [counts : (Array i32) (array.make-array i32 n)]
    [out : (Array i32) (array.make-array i32 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (cast (- (% i 17) 8) : i32))
          (array-set! counts i (count32 i))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : i32 (array-ref xs j)]
          [count : i32 (array-ref counts j)]
          (array-set!
            out
            j
            (if (< x 0)
              (shr x count)
              (if (= (bit-and x 2) 0)
                (shl x count)
                (shl x 1))))))
      (set! i 0)
      (while (< i n)
        (let
          [x : i32 (array-ref xs i)]
          [count : i32 (array-ref counts i)]
          [want : i32
            (if (< x 0)
              (shr x count)
              (if (= (bit-and x 2) 0)
                (shl x count)
                (shl x 1)))]
          (begin
            (if (!= (array-ref out i) want)
              (set! ok false)
              unit)
            (set! i (+ i 1)))))
      ok)))

(define (case-u32) : bool
  (let
    [n : i64 19]
    [xs : (Array u32) (array.make-array u32 n)]
    [counts : (Array u32) (array.make-array u32 n)]
    [out : (Array u32) (array.make-array u32 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (cast (+ (* i 17) 3) : u32))
          (array-set! counts i (cast (count32 i) : u32))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : u32 (array-ref xs j)]
          [count : u32 (array-ref counts j)]
          (array-set!
            out
            j
            (if (= (bit-and x 1) 0)
              (shr x count)
              (shl x count)))))
      (set! i 0)
      (while (< i n)
        (let
          [x : u32 (array-ref xs i)]
          [count : u32 (array-ref counts i)]
          [want : u32
            (if (= (bit-and x 1) 0)
              (shr x count)
              (shl x count))]
          (begin
            (if (!= (array-ref out i) want)
              (set! ok false)
              unit)
            (set! i (+ i 1)))))
      ok)))

(define (case-i64) : bool
  (let
    [n : i64 13]
    [xs : (Array i64) (array.make-array i64 n)]
    [counts : (Array i64) (array.make-array i64 n)]
    [out : (Array i64) (array.make-array i64 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (- i 7))
          (array-set! counts i (count64 i))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : i64 (array-ref xs j)]
          [count : i64 (array-ref counts j)]
          (array-set!
            out
            j
            (if (< x 0)
              (shr x count)
              (shl x count)))))
      (set! i 0)
      (while (< i n)
        (let
          [x : i64 (array-ref xs i)]
          [count : i64 (array-ref counts i)]
          [want : i64
            (if (< x 0)
              (shr x count)
              (shl x count))]
          (begin
            (if (!= (array-ref out i) want)
              (set! ok false)
              unit)
            (set! i (+ i 1)))))
      ok)))

(define (case-u64) : bool
  (let
    [n : i64 13]
    [xs : (Array u64) (array.make-array u64 n)]
    [counts : (Array u64) (array.make-array u64 n)]
    [out : (Array u64) (array.make-array u64 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (cast (+ (* i 31) 5) : u64))
          (array-set! counts i (cast (count64 i) : u64))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : u64 (array-ref xs j)]
          [count : u64 (array-ref counts j)]
          (array-set!
            out
            j
            (if (= (bit-and x 1) 0)
              (shr x count)
              (shl x count)))))
      (set! i 0)
      (while (< i n)
        (let
          [x : u64 (array-ref xs i)]
          [count : u64 (array-ref counts i)]
          [want : u64
            (if (= (bit-and x 1) 0)
              (shr x count)
              (shl x count))]
          (begin
            (if (!= (array-ref out i) want)
              (set! ok false)
              unit)
            (set! i (+ i 1)))))
      ok)))

(define (main) : i64
  (begin
    (unless (case-i32) (return 1))
    (unless (case-u32) (return 2))
    (unless (case-i64) (return 3))
    (unless (case-u64) (return 4))
    42))