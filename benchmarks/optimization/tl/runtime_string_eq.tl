(import "stdlib/io.tl")

(import "stdlib/string.tl")

(define (score-bool [value : bool] [score : i64]) : i64
  (if value
    score
    0))

(define (string-eq-round
  [text : String]
  [same : String]
  [first-mismatch : String]
  [late-mismatch : String]
  [empty : String]
  [short : String]) : i64
  (let
    [acc : i64 0]
    (begin
      (set! acc (+ acc (score-bool (string-eq empty "") 1)))
      (set! acc (+ acc (score-bool (string-eq short short) 3)))
      (set! acc (+ acc (score-bool (string-eq text same) 5)))
      (set! acc (+ acc (score-bool (string-eq text first-mismatch) 7)))
      (set! acc (+ acc (score-bool (string-eq text late-mismatch) 11)))
      acc)))

(define (string-eq-repeat [text : String] [short : String] [rounds : i64]) : i64
  (let
    [i : i64 0]
    [n : i64 (string-length text)]
    [empty : String (substring text 0 0)]
    [same : String (string-append text empty)]
    [first-mismatch : String (string-append "!" (substring text 1 (- n 1)))]
    [late-mismatch : String (string-append (substring text 0 (- n 1)) "!")]
    [acc : i64 0]
    (begin
      (while (< i rounds)
        (begin
          (set!
            acc
            (+
              acc
              (string-eq-round
                text
                same
                first-mismatch
                late-mismatch
                empty
                short)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [text : String (arg 1)]
    [short : String (arg 2)]
    [rounds : i64 (string->int (arg 3))]
    (begin
      (print (string-eq-repeat text short rounds))
      0)))