(import stdlib.string)

(define (leak [n : i64]) : (Tuple String i64)
  (with-arena
    phase
    (let
      [pair (tuple (string.int->string n) n)]
      (return pair)))
  (tuple "" 0))

(define (main) : i64
  (let
    [pair (leak -5)]
    (string.string-length (tuple-ref pair 0))))