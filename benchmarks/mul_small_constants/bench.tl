;# Serial wrapping multiply/xor recurrence exercising factors 3, 5, and 9.
;# The logical shifts carry high bits back to the low byte and prevent affine
;# recurrence folding. Runtime argc fixes the trip count for the C comparison.
(import stdlib.io)

(define (main) : i64
  (let
    [acc : u64 (cast 16777215 : u64)]
    [i : i64 0]
    [iterations : i64 (+ 50000000 (io.arg-count))]
    (begin
      (while (< i iterations)
        (begin
          (set! acc (bit-xor (* acc (cast 3 : u64)) (shr acc 29)))
          (set! acc (bit-xor (* acc (cast 5 : u64)) (shr acc 31)))
          (set! acc (bit-xor (* acc (cast 9 : u64)) (shr acc 27)))
          (set! i (+ i 1))))
      (cast (bit-and acc (cast 255 : u64)) : i64))))