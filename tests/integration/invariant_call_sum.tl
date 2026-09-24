(import stdlib.io)

(define (probe [values : (& values (__tl_dyn-array i64))] [divisor : i64]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i (array-length values))
        (begin
          (set! total (+ total (array-ref values i)))
          (set! i (+ i 1))))
      (/ total divisor))))

(define (probe-u [values : (& values (__tl_dyn-array u64))]) : u64
  (let
    [i : i64 0]
    [total : u64 0]
    (begin
      (while (< i (array-length values))
        (begin
          (set! total (+ total (array-ref values i)))
          (set! i (+ i 1))))
      total)))

(define (signed-run
  [values : (& values (__tl_dyn-array i64))]
  [end : i64]
  [start : i64]
  [seed : i64]
  [divisor : i64]) : i64
  (let
    [i : i64 start]
    [total : i64 seed]
    (begin
      (while (< i end)
        (begin
          (set! total (+ total (probe values divisor)))
          (set! i (+ i 1))))
      (+ total i))))

(define (unsigned-run
  [values : (& values (__tl_dyn-array u64))]
  [end : u64]
  [start : u64]
  [seed : u64]) : u64
  (let
    [i : u64 start]
    [total : u64 seed]
    (begin
      (while (< i end)
        (begin
          (set! total (+ total (probe-u values)))
          (set! i (+ i 1))))
      (+ total i))))

(define (main) : i64
  (let
    [values : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [unsigned : (__tl_dyn-array u64) (__tl_make-array u64 8)]
    [i : i64 0]
    [checksum : i64 0]
    (begin
      (while (< i 8)
        (begin
          (set! (array-ref values i) (+ i (io.arg-count)))
          (set! (array-ref unsigned i) (cast (+ i (io.arg-count)) : u64))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i 129)
        (begin
          (set!
            checksum
            (+
              (* checksum 31)
              (signed-run (& values) (- i 8) (- 0 5) 9223372036854775800 2)))
          (set! i (+ i 1))))
      (io.println
        "{} {} {} {} {} {}"
        checksum
        (signed-run (& values) (- (io.arg-count) 1) 0 7 0)
        (signed-run (& values) (- 0 1) 0 9 0)
        (signed-run
          (& values)
          9223372036854775807
          9223372036854775802
          9223372036854775800
          1)
        (signed-run
          (& values)
          -9223372036854775803
          -9223372036854775808
          -9223372036854775801
          1)
        (unsigned-run
          (& unsigned)
          18446744073709551615
          18446744073709551611
          18446744073709551605))
      0)))