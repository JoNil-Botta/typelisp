;; Refs #9420, section 5: pointer stores change local storage.
(import stdlib.io)

(define (sum-off [p : (MutPtr i64)] [start : i64] [k : i64]) : i64
  (let
    [off : i64 start]
    [po : (MutPtr i64)
      (unsafe
        (ptr-addr-of off))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i k)
      (set!
        acc
        (+
          acc
          (unsafe
            (ptr-read (ptr-offset p (+ off i))))))
      (unsafe
        (ptr-write! po 4))
      (set! i (+ i 1)))
    acc))

(define (main) : i64
  (let
    [arr : (Array i64 16) (array 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16)]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of (array-ref arr 0)))]
    ;; a=1: off=0 then 4; i=0..5: 1 + 6+7+8+9+10 = 41 -> +1 = 42
    (+ 1 (sum-off p (- (io.arg-count) 1) (+ 5 (io.arg-count))))))