(define (scan-once [text : String]) : i64
  (let
    [i : i64 0]
    [n : i64 (string-length text)]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (if (= (string-ref text i) #a')
            (set! acc (+ acc 3))
            (if (= (string-ref text i) #z')
              (set! acc (+ acc 7))
              (set! acc (+ acc 1))))
          (set! i (+ i 1))))
      acc)))

(define (scan-repeat [text : String] [rounds : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i rounds)
        (begin
          (set! acc (+ acc (scan-once text)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [text : String (arg 1)]
    [rounds : i64 (string->int (arg 2))]
    (begin
      (print (scan-repeat text rounds))
      0)))