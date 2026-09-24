(import stdlib.io)

(define (probe [values : (& values (__tl_dyn-array u64))] [divisor : u64]) : u64
  (let
    [i : i64 0]
    [total : u64 0]
    (begin
      (while (< i (array-length values))
        (begin
          (set! total (+ total (array-ref values i)))
          (set! i (+ i 1))))
      (/ total divisor))))

(define (repeat
  [values : (& values (__tl_dyn-array u64))]
  [rounds : i64]
  [seed : u64]
  [divisor : u64]) : u64
  (let
    [i : i64 0]
    [total : u64 seed]
    (begin
      (while (< i rounds)
        (begin
          (set!
            total
            (+ (* total 33) (bit-xor (probe values divisor) (cast i : u64))))
          (set! i (+ i 1))))
      total)))

(define (reference [value : u64] [rounds : i64] [seed : u64]) : u64
  (let
    [i : i64 0]
    [total : u64 seed]
    (begin
      (while (< i rounds)
        (begin
          (set! total (+ (* total 33) (bit-xor value (cast i : u64))))
          (set! i (+ i 1))))
      total)))

(define (main) : i64
  (let
    [values : (__tl_dyn-array u64) (__tl_make-array u64 8)]
    [i : i64 0]
    [n : i64 -2]
    [digest : u64 0]
    (begin
      (while (< i 8)
        (begin
          (set! (array-ref values i) (cast (+ i 1) : u64))
          (set! i (+ i 1))))
      (while (< n 130)
        (let
          [seed : u64 (+ 18446744073709551493 (cast n : u64))]
          [actual : u64
            (repeat
              (& values)
              n
              seed
              (if (> n 0)
                2
                0))]
          (begin
            (when (!= actual (reference 18 n seed)) (return 1))
            (set! digest (bit-xor digest actual))
            (set! n (+ n 1)))))
      (io.println "{}" digest)
      0)))