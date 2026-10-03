(import stdlib.io)
(import stdlib.string)

(define (bench [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 1]
    (while (< i n)
      (set! acc (% (+ (* acc 31) (+ (* i 17) 7)) 1000000007))
      (set! i (+ i 1)))
    acc))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    (io.println "{}" (bench n))
    0))