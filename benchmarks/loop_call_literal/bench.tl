(import stdlib.io)
(import stdlib.string)

(define (read-sum [values : (& values (__tl_dyn-array u64))] [bias : u64]) : u64
  (let
    [i : i64 0]
    [total : u64 bias]
    (begin
      (while (< i (array-length values))
        (begin
          (set! total (+ total (array-ref values i)))
          (set! i (+ i 1))))
      total)))

(define (repeat-sum [values : (& values (__tl_dyn-array u64))] [rounds : i64]) : u64
  (let
    [i : i64 0]
    [total : u64 0]
    (begin
      (while (< i rounds)
        (begin
          (set!
            total
            (+ (* total 33) (bit-xor (read-sum values 7) (cast i : u64))))
          (set! i (+ i 1))))
      total)))

(define (main) : i64
  (let
    [seed : u64 (cast (string.>int (io.arg 1)) : u64)]
    [rounds : i64 (string.>int (io.arg 2))]
    [values : (__tl_dyn-array u64) (__tl_make-array u64 64)]
    [i : i64 0]
    (begin
      (while (< i 64)
        (begin
          (set! (array-ref values i) (+ seed (cast (* i 17) : u64)))
          (set! i (+ i 1))))
      (io.println "{}" (repeat-sum (& values) rounds))
      0)))