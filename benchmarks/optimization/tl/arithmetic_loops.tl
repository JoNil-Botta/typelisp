(define (bench [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 1]
    (begin
      (while (< i n)
        (begin
          (set! acc (% (+ (* acc 31) (+ (* i 17) 7)) 1000000007))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string->int (arg 1))]
    (begin
      (print (bench n))
      0)))