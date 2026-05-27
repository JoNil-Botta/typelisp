(define (string-int-repeat [seed-text : String] [rounds : i64]) : i64
  (let
    [seed : i64 (string->int seed-text)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i rounds)
        (let
          [n : i64 (+ seed i)]
          [text : String (int->string n)]
          [roundtrip : i64 (string->int text)]
          (begin
            (set! acc (+ acc (+ roundtrip (string-length text))))
            (set! i (+ i 1)))))
      acc)))

(define (main) : i64
  (let
    [seed : String (arg 1)]
    [rounds : i64 (string->int (arg 2))]
    (begin
      (print (string-int-repeat seed rounds))
      0)))