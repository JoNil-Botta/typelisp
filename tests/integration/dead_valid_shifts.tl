(import stdlib.io)
(import stdlib.string)

(define calls : i64
  0)

(define (touch [value : i64]) : i64
  (begin
    (set! calls (+ calls 1))
    value))

(define (discard-valid [value : i64]) : unit
  (begin
    (shl (touch value) (cast 31 : i8))
    (shr (touch value) (cast 63 : u64))
    (shl (cast (touch value) : u8) (cast 7 : u8))
    (shr (cast (touch value) : i16) 15)
    unit))

(define (discard-dynamic [value : i64] [count : i64]) : unit
  (begin
    (shl value count)
    unit))

(define (main) : i64
  (if (> (io.arg-count) 1)
    (begin
      (discard-dynamic (io.arg-count) (string.>int (io.arg 1)))
      42)
    (begin
      (discard-valid (io.arg-count))
      (if (= calls 4)
        42
        1))))