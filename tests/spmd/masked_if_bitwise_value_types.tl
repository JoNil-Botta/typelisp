;; SPMD masked-value corpus (#5364): integer bit-or/bit-xor across every
;; contiguous integer lane width. Each case has a non-full AVX2/AVX-512 tail;
;; the leading literals, nested value-producing match, and post-loop scalar
;; checks exercise contextual typing and scalar/SIMD equivalence.
(import stdlib.array)

(define (case-i8) : bool
  (let
    [n : i64 67]
    [xs : (Array i8) (array.make-array i8 n)]
    [out : (Array i8) (array.make-array i8 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (cast (+ i 3) : i8))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : i8 (array-ref xs j)]
          (array-set!
            out
            j
            (if (= (bit-and x 1) 0)
              (bit-or 1 x)
              (if (= (bit-and x 3) 0)
                (bit-xor 3 x)
                (bit-or 2 (bit-xor 5 x)))))))
      (set! i 0)
      (while (< i n)
        (let
          [x : i8 (array-ref xs i)]
          [want : i8
            (if (= (bit-and x 1) 0)
              (bit-or 1 x)
              (if (= (bit-and x 3) 0)
                (bit-xor 3 x)
                (bit-or 2 (bit-xor 5 x))))]
          (begin
            (if (!= (array-ref out i) want)
              (set! ok false)
              unit)
            (set! i (+ i 1)))))
      ok)))

(define (case-u8) : bool
  (let
    [n : i64 67]
    [xs : (Array u8) (array.make-array u8 n)]
    [out : (Array u8) (array.make-array u8 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (cast (+ i 3) : u8))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : u8 (array-ref xs j)]
          (array-set!
            out
            j
            (if (= (bit-and x 1) 0)
              (bit-or 1 x)
              (match (bit-and x 3)
                [0 (bit-xor 3 x)]
                [_ (bit-or 2 (bit-xor 5 x))])))))
      (set! i 0)
      (while (< i n)
        (let
          [x : u8 (array-ref xs i)]
          [want : u8
            (if (= (bit-and x 1) 0)
              (bit-or 1 x)
              (match (bit-and x 3)
                [0 (bit-xor 3 x)]
                [_ (bit-or 2 (bit-xor 5 x))]))]
          (begin
            (if (!= (array-ref out i) want)
              (set! ok false)
              unit)
            (set! i (+ i 1)))))
      ok)))

(define (case-i16) : bool
  (let
    [n : i64 35]
    [xs : (Array i16) (array.make-array i16 n)]
    [out : (Array i16) (array.make-array i16 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (cast (+ i 3) : i16))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : i16 (array-ref xs j)]
          (array-set!
            out
            j
            (if (= (bit-and x 1) 0)
              (bit-or 1 x)
              (match (bit-and x 3)
                [0 (bit-xor 3 x)]
                [_ (bit-or 2 (bit-xor 5 x))])))))
      (set! i 0)
      (while (< i n)
        (let
          [x : i16 (array-ref xs i)]
          [want : i16
            (if (= (bit-and x 1) 0)
              (bit-or 1 x)
              (match (bit-and x 3)
                [0 (bit-xor 3 x)]
                [_ (bit-or 2 (bit-xor 5 x))]))]
          (begin
            (if (!= (array-ref out i) want)
              (set! ok false)
              unit)
            (set! i (+ i 1)))))
      ok)))

(define (case-u16) : bool
  (let
    [n : i64 35]
    [xs : (Array u16) (array.make-array u16 n)]
    [out : (Array u16) (array.make-array u16 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (cast (+ i 3) : u16))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : u16 (array-ref xs j)]
          (array-set!
            out
            j
            (if (= (bit-and x 1) 0)
              (bit-or 1 x)
              (match (bit-and x 3)
                [0 (bit-xor 3 x)]
                [_ (bit-or 2 (bit-xor 5 x))])))))
      (set! i 0)
      (while (< i n)
        (let
          [x : u16 (array-ref xs i)]
          [want : u16
            (if (= (bit-and x 1) 0)
              (bit-or 1 x)
              (match (bit-and x 3)
                [0 (bit-xor 3 x)]
                [_ (bit-or 2 (bit-xor 5 x))]))]
          (begin
            (if (!= (array-ref out i) want)
              (set! ok false)
              unit)
            (set! i (+ i 1)))))
      ok)))

(define (case-i32) : bool
  (let
    [n : i64 19]
    [xs : (Array i32) (array.make-array i32 n)]
    [out : (Array i32) (array.make-array i32 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (cast (+ i 3) : i32))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : i32 (array-ref xs j)]
          (array-set!
            out
            j
            (if (= (bit-and x 1) 0)
              (bit-or 1 x)
              (match (bit-and x 3)
                [0 (bit-xor 3 x)]
                [_ (bit-or 2 (bit-xor 5 x))])))))
      (set! i 0)
      (while (< i n)
        (let
          [x : i32 (array-ref xs i)]
          [want : i32
            (if (= (bit-and x 1) 0)
              (bit-or 1 x)
              (match (bit-and x 3)
                [0 (bit-xor 3 x)]
                [_ (bit-or 2 (bit-xor 5 x))]))]
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
    [out : (Array u32) (array.make-array u32 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (cast (+ i 3) : u32))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : u32 (array-ref xs j)]
          (array-set!
            out
            j
            (if (= (bit-and x 1) 0)
              (bit-or 1 x)
              (match (bit-and x 3)
                [0 (bit-xor 3 x)]
                [_ (bit-or 2 (bit-xor 5 x))])))))
      (set! i 0)
      (while (< i n)
        (let
          [x : u32 (array-ref xs i)]
          [want : u32
            (if (= (bit-and x 1) 0)
              (bit-or 1 x)
              (match (bit-and x 3)
                [0 (bit-xor 3 x)]
                [_ (bit-or 2 (bit-xor 5 x))]))]
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
    [out : (Array i64) (array.make-array i64 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (+ i 3))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : i64 (array-ref xs j)]
          (array-set!
            out
            j
            (if (= (bit-and x 1) 0)
              (bit-or 1 x)
              (match (bit-and x 3)
                [0 (bit-xor 3 x)]
                [_ (bit-or 2 (bit-xor 5 x))])))))
      (set! i 0)
      (while (< i n)
        (let
          [x : i64 (array-ref xs i)]
          [want : i64
            (if (= (bit-and x 1) 0)
              (bit-or 1 x)
              (match (bit-and x 3)
                [0 (bit-xor 3 x)]
                [_ (bit-or 2 (bit-xor 5 x))]))]
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
    [out : (Array u64) (array.make-array u64 n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (cast (+ i 3) : u64))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (let
          [x : u64 (array-ref xs j)]
          (array-set!
            out
            j
            (if (= (bit-and x 1) 0)
              (bit-or 1 x)
              (match (bit-and x 3)
                [0 (bit-xor 3 x)]
                [_ (bit-or 2 (bit-xor 5 x))])))))
      (set! i 0)
      (while (< i n)
        (let
          [x : u64 (array-ref xs i)]
          [want : u64
            (if (= (bit-and x 1) 0)
              (bit-or 1 x)
              (match (bit-and x 3)
                [0 (bit-xor 3 x)]
                [_ (bit-or 2 (bit-xor 5 x))]))]
          (begin
            (if (!= (array-ref out i) want)
              (set! ok false)
              unit)
            (set! i (+ i 1)))))
      ok)))

(define (main) : i64
  (begin
    (unless (case-i8) (return 1))
    (unless (case-u8) (return 2))
    (unless (case-i16) (return 3))
    (unless (case-u16) (return 4))
    (unless (case-i32) (return 5))
    (unless (case-u32) (return 6))
    (unless (case-i64) (return 7))
    (unless (case-u64) (return 8))
    42))