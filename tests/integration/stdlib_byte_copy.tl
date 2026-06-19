(import "stdlib/string.tl")
(import "stdlib/test.tl")

(define (byte-copy-u8 [value : i64]) : u8
  (cast value : u8))

(define (byte-copy-base [items : (Array u8)]) : (MutPtr u8)
  (unsafe
    (array-data items)))

(define (byte-copy-source-at [base : (MutPtr u8)] [offset : i64]) : (Ptr u8)
  (unsafe
    (ptr-cast (ptr-offset base offset) : (Ptr u8))))

(define (byte-copy-fill! [items : (Array u8)] [count : i64] [base : i64]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (array-set! items i (byte-copy-u8 (+ base i)))
        (set! i (+ i 1))))))

(define (byte-copy-fill-constant!
  [items : (Array u8)]
  [count : i64]
  [value : i64]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (array-set! items i (byte-copy-u8 value))
        (set! i (+ i 1))))))

(define (byte-copy-assert-at
  [items : (Array u8)]
  [index : i64]
  [expected : i64]
  [message : String]) : unit
  (assert-i64-eq (cast (array-ref items index) : i64) expected message))

(define (byte-copy-assert-range
  [items : (Array u8)]
  [start : i64]
  [count : i64]
  [base : i64]
  [message : String]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (byte-copy-assert-at items (+ start i) (+ base i) message)
        (set! i (+ i 1))))))

(define (byte-copy-assert-constant-range
  [items : (Array u8)]
  [start : i64]
  [count : i64]
  [expected : i64]
  [message : String]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (byte-copy-assert-at items (+ start i) expected message)
        (set! i (+ i 1))))))

(define (byte-copy-zero-length-case) : unit
  (let
    [src : (Array u8) (make-array u8 4)]
    [dst : (Array u8) (make-array u8 4)]
    [src-base : (MutPtr u8) (byte-copy-base src)]
    [dst-base : (MutPtr u8) (byte-copy-base dst)]
    (begin
      (byte-copy-fill! src 4 10)
      (byte-copy-fill-constant! dst 4 77)
      (str-copy-bytes-into (byte-copy-source-at src-base 0) dst-base 2 0)
      (byte-copy-assert-constant-range
        dst
        0
        4
        77
        "zero-length copy leaves dst unchanged"))))

(define (byte-copy-unaligned-case) : unit
  (let
    [src : (Array u8) (make-array u8 20)]
    [dst : (Array u8) (make-array u8 20)]
    [src-base : (MutPtr u8) (byte-copy-base src)]
    [dst-base : (MutPtr u8) (byte-copy-base dst)]
    [n : i64 11]
    (begin
      (byte-copy-fill! src 20 20)
      (byte-copy-fill-constant! dst 20 99)
      (str-copy-bytes-into (byte-copy-source-at src-base 1) dst-base 3 n)
      (byte-copy-assert-at dst 2 99 "unaligned prefix remains")
      (byte-copy-assert-range dst 3 n 21 "unaligned copy payload")
      (byte-copy-assert-at dst 14 99 "unaligned suffix remains"))))

(define (byte-copy-tail-case [n : i64]) : unit
  (let
    [src : (Array u8) (make-array u8 12)]
    [dst : (Array u8) (make-array u8 12)]
    [src-base : (MutPtr u8) (byte-copy-base src)]
    [dst-base : (MutPtr u8) (byte-copy-base dst)]
    (begin
      (byte-copy-fill! src 12 40)
      (byte-copy-fill-constant! dst 12 88)
      (str-copy-bytes-into (byte-copy-source-at src-base 0) dst-base 1 n)
      (byte-copy-assert-at dst 0 88 "tail prefix remains")
      (byte-copy-assert-range dst 1 n 40 "tail copy payload")
      (byte-copy-assert-at dst (+ n 1) 88 "tail suffix remains"))))

(define (byte-copy-tail-cases) : unit
  (let
    [n : i64 1]
    (while (<= n 7)
      (begin
        (byte-copy-tail-case n)
        (set! n (+ n 1))))))

(define (byte-copy-medium-dynamic-case) : unit
  (let
    [src : (Array u8) (make-array u8 96)]
    [dst : (Array u8) (make-array u8 96)]
    [src-base : (MutPtr u8) (byte-copy-base src)]
    [dst-base : (MutPtr u8) (byte-copy-base dst)]
    [n : i64 (+ 64 9)]
    (begin
      (byte-copy-fill! src 96 3)
      (byte-copy-fill-constant! dst 96 55)
      (str-copy-bytes-into (byte-copy-source-at src-base 0) dst-base 5 n)
      (byte-copy-assert-at dst 4 55 "medium prefix remains")
      (byte-copy-assert-range dst 5 n 3 "medium dynamic copy payload")
      (byte-copy-assert-at dst (+ 5 n) 55 "medium suffix remains"))))

(define (byte-copy-overlap-dst-after-src-case) : unit
  (let
    [buf : (Array u8) (make-array u8 20)]
    [base : (MutPtr u8) (byte-copy-base buf)]
    (begin
      (byte-copy-fill! buf 20 0)
      (str-copy-bytes-into (byte-copy-source-at base 0) base 3 10)
      (byte-copy-assert-range buf 0 3 0 "overlap prefix remains")
      (byte-copy-assert-range buf 3 10 0 "overlap copied payload")
      (byte-copy-assert-at buf 13 13 "overlap suffix remains"))))

(define (main) : i64
  (begin
    (byte-copy-zero-length-case)
    (byte-copy-unaligned-case)
    (byte-copy-tail-cases)
    (byte-copy-medium-dynamic-case)
    (byte-copy-overlap-dst-after-src-case)
    42))