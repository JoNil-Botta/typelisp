;; A serial wrapping multiply/xor recurrence with a wide constant multiplier.
(import stdlib.io)

(define factor : u64
  17179869184)

(define (main) : i64
  (let
    [acc : u64 (cast 16777215 : u64)]
    [i : i64 0]
    [iterations : i64 (+ 100000000 (io.arg-count))]
    (begin
      (while (< i iterations)
        (begin
          (set! acc (bit-xor (* acc factor) (shr acc 29)))
          (set! i (+ i 1))))
      (cast (bit-and acc (cast 255 : u64)) : i64))))